import AVFoundation
import Accelerate

/// Takes the others' voices out of your side when the microphone heard them from the speakers.
/// Without headphones, `you.m4a` carries the call twice: your voice, and the others coming back
/// from the speakers a little later. Their side, `them.m4a`, is exactly what the speakers played,
/// on the same clock, so after the call it can be subtracted from yours: the classic echo
/// canceller of a phone, with the whole call in hand instead of a few milliseconds.
///
/// 1. Where their sound shows up in your microphone: the cross-correlation of the two sides
///    (GCC-PHAT) over the stretches where they speak. No clear peak: no echo, the file stays as is.
/// 2. The echo path from their side to your microphone, learned as you go: a frequency-domain
///    adaptive filter (partitioned, overlap-save NLMS). A background filter learns all the time;
///    the one that cleans takes over what it learned only while that does better, so the filter
///    doesn't unlearn while both sides talk at once.
/// 3. What's left of the echo, the part a linear filter can't model (the speakers' distortion),
///    is turned down where the echo estimate dominates.
nonisolated enum EchoCanceller {
    /// Cleans `you` in place, its sound only, at its own rate and format. Returns where your side as
    /// recorded went in the Trash; `nil`: no echo found, and the file wasn't touched.
    static func clean(_ you: URL, against them: URL) throws -> URL? {
        guard let lag = try lag(of: you, behind: them) else { return nil }
        let mic = try AVAudioFile(forReading: you), reference = try AVAudioFile(forReading: them)
        let format = mic.processingFormat
        guard format.channelCount == 1, reference.processingFormat.sampleRate == format.sampleRate else { return nil }
        let cleaned = you.deletingLastPathComponent().appending(path: "you-cleaned.\(you.pathExtension)")
        try? FileManager.default.removeItem(at: cleaned)
        do {
            let out = try AVAudioFile(forWriting: cleaned, settings: mic.fileFormat.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try run(mic: mic, reference: reference, lag: lag, into: out)
        } catch {
            try? FileManager.default.removeItem(at: cleaned)
            throw error
        }
        return try keep(you, replacedWith: cleaned)
    }

    /// Your side as recorded goes to the Trash, named after its call, and `cleaned` takes its place:
    /// a filter that took your voice for their echo is undone from there. In a folder without a
    /// Trash (a server), your side stays as recorded.
    private static func keep(_ you: URL, replacedWith cleaned: URL) throws -> URL {
        let files = FileManager.default
        let call = you.deletingLastPathComponent()
        let recorded = call.appending(path: String(localized: "\(call.lastPathComponent) — your side before echo removal") + ".\(you.pathExtension)")
        var trashed: NSURL?
        do {
            try files.moveItem(at: you, to: recorded)
            do {
                try files.trashItem(at: recorded, resultingItemURL: &trashed)
                try files.moveItem(at: cleaned, to: you)
            } catch {
                try? files.moveItem(at: (trashed as URL?) ?? recorded, to: you)
                throw error
            }
        } catch {
            try? files.removeItem(at: cleaned)
            throw error
        }
        return (trashed as URL?) ?? recorded
    }

    /// Each side through the filter, a block at a time, into `out`, with as many samples as the
    /// microphone's file and on its timeline.
    private static func run(mic: AVAudioFile, reference: AVAudioFile, lag: Int, into out: AVAudioFile) throws {
        let filter = EchoFilter()
        let block = filter.block
        // The filter sees their sound a few milliseconds before it reaches the microphone: delay
        // whichever side comes first. A filter's output is one block late (its overlap-add).
        let micDelay = max(0, EchoFilter.lead - lag), referenceDelay = max(0, lag - EchoFilter.lead)
        let skip = micDelay + block
        let length = Int(mic.length)
        let micIn = Stream(mic, delay: micDelay), referenceIn = Stream(reference, delay: referenceDelay)
        let chunk = AVAudioPCMBuffer(pcmFormat: mic.processingFormat, frameCapacity: AVAudioFrameCount(block * 64))!
        let samples = chunk.floatChannelData![0]
        var cleaned = [Float](repeating: 0, count: block)
        var micBlock = [Float](repeating: 0, count: block), referenceBlock = [Float](repeating: 0, count: block)
        var produced = 0, written = 0
        while written < length {
            try micIn.read(into: &micBlock)
            try referenceIn.read(into: &referenceBlock)
            filter.process(mic: micBlock, reference: referenceBlock, into: &cleaned)
            // The first `skip` samples are the delays; past them, the microphone's timeline.
            let from = max(0, skip - produced)
            produced += block
            guard from < block else { continue }
            let count = min(block - from, length - written)
            let start = Int(chunk.frameLength)
            cleaned.withUnsafeBufferPointer { (samples + start).update(from: $0.baseAddress! + from, count: count) }
            chunk.frameLength += AVAudioFrameCount(count)
            written += count
            if chunk.frameLength + AVAudioFrameCount(block) > chunk.frameCapacity || written == length {
                try out.write(from: chunk)
                chunk.frameLength = 0
            }
        }
    }

    // MARK: Where the echo is

    /// Samples from their sound to its echo in your microphone: negative when the microphone hears
    /// it first, as when the Mac hands their side over late. `nil`: nothing their side says comes
    /// back in yours (headphones), or not clearly enough to tell where.
    static func lag(of you: URL, behind them: URL) throws -> Int? {
        let mic = try AVAudioFile(forReading: you), reference = try AVAudioFile(forReading: them)
        let rate = mic.processingFormat.sampleRate
        let window = 1 << 17, size = 1 << 18 // 2.7 s at 48 kHz, padded for a correlation without wrap-around
        let range = Int(rate / 2) // half a second either way
        let fft = FFT(size: size)
        let voice = Int(100 / rate * Double(size))..<Int(8000 / rate * Double(size)) // bins of 100 Hz to 8 kHz
        let micWindow = AVAudioPCMBuffer(pcmFormat: mic.processingFormat, frameCapacity: AVAudioFrameCount(window))!
        let referenceWindow = AVAudioPCMBuffer(pcmFormat: reference.processingFormat, frameCapacity: AVAudioFrameCount(window))!
        var found: [Int] = []
        var tried = 0
        // The first ten minutes say it: the echo path stays put within a call.
        while tried < Int(600 * rate) / window, found.count < 9,
              (try? mic.read(into: micWindow, frameCount: AVAudioFrameCount(window))) != nil,
              (try? reference.read(into: referenceWindow, frameCount: AVAudioFrameCount(window))) != nil,
              Int(micWindow.frameLength) == window, Int(referenceWindow.frameLength) == window {
            tried += 1
            let x = UnsafeBufferPointer(start: referenceWindow.floatChannelData![0], count: window)
            let y = UnsafeBufferPointer(start: micWindow.floatChannelData![0], count: window)
            guard vDSP.rootMeanSquare(x) > 0.003, vDSP.rootMeanSquare(y) > 0.0003 else { continue } // they speak, the mic hears something
            if let lag = fft.peak(of: y, against: x, within: range, band: voice) { found.append(lag) }
        }
        // Most windows agree to within a millisecond, or it's no echo anyone would hear.
        guard found.count >= 3 else { return nil }
        let median = found.sorted()[found.count / 2]
        let agreeing = found.filter { abs($0 - median) <= Int(rate / 1000) }
        return agreeing.count * 5 >= found.count * 3 ? median : nil
    }
}

/// One cancelling filter, block by block: the adaptive filter, then the suppressor of what's left.
/// Its learning follows Speex's echo canceller (J.-M. Valin, "On Adjusting the Learning Rate in
/// Frequency Domain Echo Cancellation With Double-Talk", 2007): each frequency learns as fast as
/// the echo is what's left there, so it all but stops while you talk over the others.
/// Everything is allocated once, and the per-frequency loops run on the buffers themselves, not
/// through checked array accesses: an hour of call is 340,000 blocks. Measured on an M-series Mac:
/// 6 s of CPU per hour of them talking, plus 7 s to read both sides and encode yours again; none while they're quiet.
nonisolated final class EchoFilter {
    /// Samples per block: 10.7 ms at 48 kHz.
    let block = 512
    /// Blocks of echo path the filter holds: 16 × 512, 170 ms at 48 kHz, room echo included.
    private let partitions = 16
    /// Where in the filter the echo's direct path goes: 128 samples, 2.7 ms, for what comes slightly earlier.
    static let lead = 128

    private let fft: FFT
    private let bins: Int
    /// Square-root Hann: analysis and synthesis together add up to one at half overlap.
    private let window: [Float]
    /// Their side's spectra, one per partition; `newest` is the one just made.
    private let history: [Split]
    private var newest = 0
    /// Their power per bin, smoothed over half a second: what each step is divided by.
    private var power: [Float]
    /// The filter that cleans, and the one that learns.
    private let cleaning: [Split], learning: [Split]
    /// Blocks in a row in which they said nothing at all: past the filter's length, there's no echo to remove.
    private var quiet = Int.max
    private var constrained = 0
    /// How much better the learning filter does, fast and slow, and how much that varies.
    private var ahead = (fast: Float(0), slow: Float(0)), spread = (fast: Float(0), slow: Float(0))
    /// The share of the echo estimate that's left in the error: a regression of the error's
    /// spectrum on the estimate's, from block to block.
    private var errorMean: [Float], echoMean: [Float]
    private var covariance: Float = 0, variance: Float = 0
    private var leak: Float = 0
    /// Until the filter has learned enough to judge its own leak, it learns at a plain rate.
    private var adapted = false, progress: Float = 0
    private var residual: [Float], errorPower: [Float], gain: [Float]
    /// Each partition's share of the step.
    private var shares: [Float]
    // Scratch, one block or one spectrum long.
    private var frame: [Float], echo: [Float], learnt: [Float], error: [Float], miss: [Float]
    private var previousReference: [Float], previousEcho: [Float], previousError: [Float], overlap: [Float]
    private var step: [Float], newestPower: [Float], errorNow: [Float], echoNow: [Float], deviation: [Float], echoDeviation: [Float]
    private let sum: Split, missSpectrum: Split, gradient: Split, errorSpectrum: Split, echoSpectrum: Split

    init() {
        let block = 512, partitions = 16, size = 2 * block, bins = size / 2
        let zeros = [Float](repeating: 0, count: block), spectrum = [Float](repeating: 0, count: bins)
        let spectra = { (0..<partitions).map { _ in Split(bins) } }
        fft = FFT(size: size)
        self.bins = bins
        window = (0..<size).map { sin(Float.pi * (Float($0) + 0.5) / Float(size)) }
        history = spectra()
        cleaning = spectra()
        learning = spectra()
        (power, errorMean, echoMean, residual, errorPower) = (spectrum, spectrum, spectrum, spectrum, spectrum)
        (step, newestPower, errorNow, echoNow) = (spectrum, spectrum, spectrum, spectrum)
        (deviation, echoDeviation) = (spectrum, spectrum)
        gain = [Float](repeating: 1, count: bins)
        shares = [Float](repeating: 0.99 / Float(partitions), count: partitions)
        frame = [Float](repeating: 0, count: size)
        (echo, learnt, error, miss) = (zeros, zeros, zeros, zeros)
        (previousReference, previousEcho, previousError, overlap) = (zeros, zeros, zeros, zeros)
        (sum, missSpectrum, gradient, errorSpectrum, echoSpectrum) = (Split(bins), Split(bins), Split(bins), Split(bins), Split(bins))
    }

    func process(mic: [Float], reference: [Float], into out: inout [Float]) {
        let referenceEnergy = vDSP.sumOfSquares(reference)
        quiet = referenceEnergy == 0 ? quiet &+ 1 : 0
        // Their newest spectrum over the last two blocks.
        newest = (newest + partitions - 1) % partitions
        put(previousReference, reference)
        fft.forward(frame, into: history[newest])
        previousReference.withUnsafeMutableBufferPointer { _ = $0.update(fromContentsOf: reference) }
        let smoothing = 0.35 / Float(partitions)
        history[newest].power(into: &newestPower)
        vDSP.add(multiplication: (power, 1 - smoothing), multiplication: (newestPower, smoothing), result: &power)

        if quiet > partitions {
            // Nothing they said is still echoing: the microphone as it is, with no echo to learn from.
            error.withUnsafeMutableBufferPointer { _ = $0.update(fromContentsOf: mic) }
            vDSP.fill(&echo, with: 0)
        } else {
            cancel(mic: mic)
        }

        // The error's and the echo estimate's spectra, for the leak and for what's left of the echo.
        put(previousError, error, windowed: true)
        fft.forward(frame, into: errorSpectrum)
        put(previousEcho, echo, windowed: true)
        fft.forward(frame, into: echoSpectrum)
        errorSpectrum.power(into: &errorNow)
        echoSpectrum.power(into: &echoNow)
        if quiet <= partitions { learn(referenceEnergy: referenceEnergy) }

        // What's left of the echo is turned down where it's most of what's there, by up to 20 dB:
        // at once as it comes, gently back.
        vDSP.add(multiplication: (residual, 0.6), multiplication: (echoNow, 0.4 * leak), result: &residual)
        vDSP.add(multiplication: (errorPower, 0.6), multiplication: (errorNow, 0.4), result: &errorPower)
        residual.withUnsafeBufferPointer { residual in errorPower.withUnsafeBufferPointer { errorPower in gain.withUnsafeMutableBufferPointer { gain in
            for bin in 0..<bins {
                let target = max(0.1, 1 - 2 * residual[bin] / (errorPower[bin] + 1e-12))
                gain[bin] = target < gain[bin] ? target : 0.5 * gain[bin] + 0.5 * target
            }
        }}}
        errorSpectrum.scale(by: gain)
        fft.inverse(errorSpectrum, into: &frame)
        vDSP.multiply(frame, window, result: &frame)
        vDSP.add(overlap, frame[0..<block], result: &out)
        overlap.withUnsafeMutableBufferPointer { _ = $0.update(fromContentsOf: frame[block...]) }
        // This block's for the next one's spectra. Both are written anew before they're read again.
        swap(&previousError, &error)
        swap(&previousEcho, &echo)
    }

    /// Both filters' echo, and which of them cleans: the learning one takes over once it does
    /// clearly better; it goes back to the cleaning one when it clearly went astray.
    private func cancel(mic: [Float]) {
        estimate(with: cleaning, into: &echo)
        estimate(with: learning, into: &learnt)
        vDSP.subtract(mic, echo, result: &error)
        vDSP.subtract(mic, learnt, result: &miss)
        let cleaningError = vDSP.sumOfSquares(error), learningError = vDSP.sumOfSquares(miss)
        let apart = vDSP.distanceSquared(error, miss) + 1e-9
        let better = cleaningError - learningError
        ahead = (0.6 * ahead.fast + 0.4 * better, 0.85 * ahead.slow + 0.15 * better)
        spread = (0.36 * spread.fast + 0.16 * cleaningError * apart, 0.7225 * spread.slow + 0.0225 * cleaningError * apart)
        let signedSquare = { (x: Float) in x * abs(x) }
        if signedSquare(better) > cleaningError * apart || signedSquare(ahead.fast) > 0.5 * spread.fast || signedSquare(ahead.slow) > 0.25 * spread.slow {
            for p in 0..<partitions { cleaning[p].copy(learning[p]) }
            // Crossfaded over the block, so the switch doesn't click.
            for i in 0..<block {
                let t = Float(i) / Float(block)
                error[i] = (1 - t) * error[i] + t * miss[i]
                echo[i] = (1 - t) * echo[i] + t * learnt[i]
            }
            (ahead, spread) = ((0, 0), (0, 0))
        } else if signedSquare(-better) > 4 * cleaningError * apart || signedSquare(-ahead.fast) > 4 * spread.fast || signedSquare(-ahead.slow) > 4 * spread.slow {
            for p in 0..<partitions { learning[p].copy(cleaning[p]) }
            (learnt, miss) = (echo, error)
            (ahead, spread) = ((0, 0), (0, 0))
        }
    }

    /// The learning filter's step toward the echo path, per frequency as fast as the echo is
    /// what's left there.
    private func learn(referenceEnergy: Float) {
        // How much of the echo estimate is left in the error.
        let errorEnergy = vDSP.sumOfSquares(error) + 1e-9, echoEnergy = vDSP.sumOfSquares(echo)
        let average = Float(block) / 48_000 // Speex's time constants, in blocks at 48 kHz
        vDSP.subtract(errorNow, errorMean, result: &deviation)
        vDSP.subtract(echoNow, echoMean, result: &echoDeviation)
        let spreadNow = max(vDSP.sumOfSquares(echoDeviation).squareRoot(), 1e-12)
        let covarianceNow = vDSP.dot(deviation, echoDeviation) / spreadNow
        vDSP.add(multiplication: (errorMean, 1 - average), multiplication: (errorNow, average), result: &errorMean)
        vDSP.add(multiplication: (echoMean, 1 - average), multiplication: (echoNow, average), result: &echoMean)
        let alpha = min(2 * average * echoEnergy, 0.5 * average * errorEnergy) / errorEnergy
        covariance = (1 - alpha) * covariance + alpha * covarianceNow
        variance = max((1 - alpha) * variance + alpha * spreadNow, 1e-9)
        covariance = min(max(covariance, 0.005 * variance), variance) // better than 23 dB isn't to be hoped for anyway
        leak = covariance / variance
        // The residual-to-error ratio: how much of what's left is echo.
        let crossEnergy = vDSP.dot(error, echo)
        let residualRatio = min(max((1e-4 * referenceEnergy + 3 * leak * echoEnergy) / errorEnergy,
                                    crossEnergy * crossEnergy / (1e-9 + errorEnergy * echoEnergy)), 0.5)
        // A floor at a whisper (−60 dBFS): their silence is often exact zeros.
        let floor = Float(8 * block) * 1e-6
        if adapted {
            let leak = leak
            errorNow.withUnsafeBufferPointer { errorNow in echoNow.withUnsafeBufferPointer { echoNow in power.withUnsafeBufferPointer { power in step.withUnsafeMutableBufferPointer { step in
                for bin in 0..<bins {
                    let e = errorNow[bin] + 1e-12
                    let r = 0.7 * min(leak * echoNow[bin], e / 2) + 0.3 * residualRatio * e
                    step[bin] = r / (e * (power[bin] + floor))
                }
            }}}}
        } else {
            let plain = referenceEnergy > 1e-5 ? min(0.25 * referenceEnergy, errorEnergy / 4) / errorEnergy : 0
            power.withUnsafeBufferPointer { power in step.withUnsafeMutableBufferPointer { step in
                for bin in 0..<bins { step[bin] = plain / (power[bin] + floor) }
            }}
            progress += plain
            adapted = progress > Float(partitions) && leak > 0.03
        }
        vDSP.fill(&frame[0..<block], with: 0)
        frame.withUnsafeMutableBufferPointer { _ = UnsafeMutableBufferPointer(rebasing: $0[block...]).update(fromContentsOf: miss) }
        fft.forward(frame, into: missSpectrum)
        gradient.copy(missSpectrum)
        gradient.scale(by: step)
        // Partitions holding more of the echo path learn faster (proportionate NLMS).
        // They change slowly: every fourth block is often enough.
        if constrained % 4 == 0 {
            let weights = learning.map { ($0.energy() + 1).squareRoot() }
            let strongest = weights.max() ?? 1
            let total = weights.reduce(1) { $0 + $1 + 0.1 * strongest }
            shares = weights.map { 0.99 * ($0 + 0.1 * strongest) / total }
        }
        var previous: Float = 1
        for p in 0..<partitions {
            gradient.scale(by: shares[p] / previous) // from the last partition's share to this one's
            previous = shares[p]
            learning[p].add(conjugateOf: history[(newest + p) % partitions], times: gradient)
        }
        // Keep one partition's filter causal per block, in turn: the full constraint for each of
        // them on every block costs two transforms apiece, and turn by turn is enough.
        constrained = (constrained + 1) % partitions
        fft.inverse(learning[constrained], into: &frame)
        vDSP.fill(&frame[block...], with: 0)
        fft.forward(frame, into: learning[constrained])
    }

    /// The echo the filter predicts for this block: their past through the filter's partitions.
    private func estimate(with filter: [Split], into echo: inout [Float]) {
        sum.zero()
        for p in 0..<partitions { sum.add(history[(newest + p) % partitions], times: filter[p]) }
        fft.inverse(sum, into: &frame)
        echo.withUnsafeMutableBufferPointer { _ = $0.update(fromContentsOf: frame[block...]) }
    }

    /// Two blocks, one after the other, into `frame`, through the window if asked.
    private func put(_ first: [Float], _ second: [Float], windowed: Bool = false) {
        frame.withUnsafeMutableBufferPointer { frame in
            _ = frame.update(fromContentsOf: first)
            _ = UnsafeMutableBufferPointer(rebasing: frame[block...]).update(fromContentsOf: second)
        }
        if windowed { vDSP.multiply(frame, window, result: &frame) }
    }
}

/// A file's mono sound in blocks, after `delay` samples of silence, and silence once it ends.
nonisolated private final class Stream {
    private let file: AVAudioFile
    private let buffer: AVAudioPCMBuffer
    private var pending: [Float]
    private var position = 0

    init(_ file: AVAudioFile, delay: Int) {
        self.file = file
        buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1 << 16)!
        pending = [Float](repeating: 0, count: delay)
    }

    func read(into block: inout [Float]) throws {
        while pending.count - position < block.count {
            pending.removeFirst(position)
            position = 0
            if file.framePosition < file.length { try file.read(into: buffer, frameCount: buffer.frameCapacity) } else { buffer.frameLength = 0 }
            if buffer.frameLength == 0 { pending += [Float](repeating: 0, count: block.count) } // the end
            else { pending += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)) }
        }
        block.withUnsafeMutableBufferPointer { _ = $0.update(fromContentsOf: pending[position..<position + $0.count]) }
        position += block.count
    }
}

// MARK: - Spectra

/// Half a spectrum, as vDSP's real transforms pack it: bin 0 holds the DC part in `real` and the
/// Nyquist part in `imaginary`, both real numbers; the others are complex. Changed in place, in
/// memory of its own: no copies, no checks on the way in a loop that runs half a million times.
nonisolated final class Split {
    let real: UnsafeMutablePointer<Float>, imaginary: UnsafeMutablePointer<Float>
    let count: Int

    init(_ bins: Int) {
        count = bins
        real = .allocate(capacity: bins)
        imaginary = .allocate(capacity: bins)
        zero()
    }

    deinit {
        real.deallocate()
        imaginary.deallocate()
    }

    func zero() {
        real.update(repeating: 0, count: count)
        imaginary.update(repeating: 0, count: count)
    }

    func copy(_ other: Split) {
        real.update(from: other.real, count: count)
        imaginary.update(from: other.imaginary, count: count)
    }

    /// |z|², DC alone in bin 0 (Nyquist is nothing in a voice).
    func power(into power: inout [Float]) {
        power.withUnsafeMutableBufferPointer { power in
            vDSP_vsq(real, 1, power.baseAddress!, 1, vDSP_Length(count))
            vDSP_vma(imaginary, 1, imaginary, 1, power.baseAddress!, 1, power.baseAddress!, 1, vDSP_Length(count))
            power[0] = real[0] * real[0]
        }
    }

    /// Σ|z|².
    func energy() -> Float {
        var a: Float = 0, b: Float = 0
        vDSP_svesq(real, 1, &a, vDSP_Length(count))
        vDSP_svesq(imaginary, 1, &b, vDSP_Length(count))
        return a + b
    }

    /// self += a × b.
    func add(_ a: Split, times b: Split) {
        var A = a.complex, B = b.complex, C = complex
        vDSP_zvma(&A, 1, &B, 1, &C, 1, &C, 1, vDSP_Length(count - 1))
        real[0] += a.real[0] * b.real[0] // DC
        imaginary[0] += a.imaginary[0] * b.imaginary[0] // Nyquist
    }

    /// self += conj(a) × b.
    func add(conjugateOf a: Split, times b: Split) {
        var A = a.complex, B = b.complex, C = complex
        vDSP_zvcma(&A, 1, &B, 1, &C, 1, &C, 1, vDSP_Length(count - 1))
        real[0] += a.real[0] * b.real[0]
        imaginary[0] += a.imaginary[0] * b.imaginary[0]
    }

    /// Bins 1…, the complex ones.
    private var complex: DSPSplitComplex { DSPSplitComplex(realp: real + 1, imagp: imaginary + 1) }

    func scale(by factor: Float) {
        var factor = factor
        vDSP_vsmul(real, 1, &factor, real, 1, vDSP_Length(count))
        vDSP_vsmul(imaginary, 1, &factor, imaginary, 1, vDSP_Length(count))
    }

    /// Each bin by its own factor; Nyquist by DC's.
    func scale(by factors: [Float]) {
        vDSP_vmul(real, 1, factors, 1, real, 1, vDSP_Length(count))
        vDSP_vmul(imaginary, 1, factors, 1, imaginary, 1, vDSP_Length(count))
    }
}

/// vDSP's real transform of one size, scaled so `inverse(forward(x)) == x`.
nonisolated final class FFT {
    private let size: Int
    private let forwardSetup: vDSP_DFT_Setup, inverseSetup: vDSP_DFT_Setup
    private var even: [Float], odd: [Float]

    init(size: Int) {
        self.size = size
        forwardSetup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(size), .FORWARD)!
        inverseSetup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(size), .INVERSE)!
        even = [Float](repeating: 0, count: size / 2)
        odd = [Float](repeating: 0, count: size / 2)
    }

    deinit {
        vDSP_DFT_DestroySetup(forwardSetup)
        vDSP_DFT_DestroySetup(inverseSetup)
    }

    func forward(_ signal: [Float], into spectrum: Split) {
        signal.withUnsafeBufferPointer { signal in
            even.withUnsafeMutableBufferPointer { even in odd.withUnsafeMutableBufferPointer { odd in
                var split = DSPSplitComplex(realp: even.baseAddress!, imagp: odd.baseAddress!)
                signal.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(size / 2)) }
            }}
        }
        vDSP_DFT_Execute(forwardSetup, even, odd, spectrum.real, spectrum.imaginary)
    }

    func inverse(_ spectrum: Split, into signal: inout [Float]) {
        vDSP_DFT_Execute(inverseSetup, spectrum.real, spectrum.imaginary, &even, &odd)
        even.withUnsafeMutableBufferPointer { even in odd.withUnsafeMutableBufferPointer { odd in
            var split = DSPSplitComplex(realp: even.baseAddress!, imagp: odd.baseAddress!)
            signal.withUnsafeMutableBufferPointer { signal in
                signal.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) { vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(size / 2)) }
            }
        }}
        vDSP.multiply(1 / Float(2 * size), signal, result: &signal)
    }

    /// The lag at which `y` best matches `x` (GCC-PHAT), within ±`range` samples, if it stands out:
    /// a peak at least 8 times the correlation's typical size, as an echo's does and chance's doesn't.
    /// `band`: the bins to compare.
    func peak(of y: UnsafeBufferPointer<Float>, against x: UnsafeBufferPointer<Float>, within range: Int, band: Range<Int>) -> Int? {
        let bins = size / 2
        let padded = { (signal: UnsafeBufferPointer<Float>) in Array(signal) + [Float](repeating: 0, count: self.size - signal.count) }
        let X = Split(bins), Y = Split(bins), cross = Split(bins)
        forward(padded(x), into: X)
        forward(padded(y), into: Y)
        cross.add(conjugateOf: X, times: Y)
        // Phase only: every frequency of a voice counts the same, so the peak is sharp however it
        // sounds. Only a voice's frequencies: above them AAC leaves its own noise, the same in both
        // files, which peaks at no lag at all.
        var magnitude = [Float](repeating: 0, count: bins)
        cross.power(into: &magnitude)
        cross.scale(by: magnitude.indices.map { band.contains($0) ? 1 / (magnitude[$0].squareRoot() + 1e-20) : 0 })
        (cross.real[0], cross.imaginary[0]) = (0, 0)
        var correlation = [Float](repeating: 0, count: size)
        inverse(cross, into: &correlation)
        // Lags −range...range: the positive ones from the start, the negative ones wrapped from the end.
        let lags = Array(-range...range)
        let values = lags.map { abs(correlation[$0 >= 0 ? $0 : size + $0]) }
        guard let best = values.indices.max(by: { values[$0] < values[$1] }) else { return nil }
        return values[best] > 8 * vDSP.rootMeanSquare(values) ? lags[best] : nil
    }
}
