import AVFoundation
import Security

/// Any service that speaks the OpenAI `POST /audio/transcriptions` dialect:
/// Refrain, OpenAI, Groq, Mistral, or a local whisper server (speaches, whisper.cpp, LocalAI…).
nonisolated struct TranscriptionService: Sendable {
    var baseURL: String
    var model: String

    /// Refrain transcribes on this Mac's Neural Engine and picks the model itself
    /// (github.com/nikiomori/Refrain).
    static let refrain = TranscriptionService(baseURL: "http://127.0.0.1:8178/v1", model: "auto")

    static let presets: [(name: String, service: TranscriptionService)] = [
        (String(localized: "Refrain (this Mac)"), refrain),
        ("OpenAI", .init(baseURL: "https://api.openai.com/v1", model: "gpt-4o-transcribe")),
        ("Groq", .init(baseURL: "https://api.groq.com/openai/v1", model: "whisper-large-v3-turbo")),
        ("Mistral", .init(baseURL: "https://api.mistral.ai/v1", model: "voxtral-mini-latest")),
        (String(localized: "Local server"), .init(baseURL: "http://localhost:8000/v1", model: "Systran/faster-whisper-large-v3")),
    ]

    /// Whether Refrain answers on this Mac, for Settings to offer it. A second at most: it's
    /// local or it isn't there.
    static func refrainIsRunning() async -> Bool {
        guard let url = URL(string: refrain.baseURL)?.appending(path: "models"),
              let (data, response) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 1)),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return false }
        return String(decoding: data, as: UTF8.self).contains(#""owned_by":"refrain""#)
    }

    /// A server on this Mac, which takes a call whole rather than 10 minutes at a time.
    // ponytail: loopback only; a server elsewhere on the network diarizes calls up to 10 minutes.
    // Add private addresses if one should take long calls whole too.
    var isLocal: Bool { ["localhost", "127.0.0.1", "::1"].contains(URL(string: baseURL)?.host() ?? "") }

    /// Refrain takes hours in one request, so it never gets pieces: no re-encoding, no context lost at a cut.
    /// Other local servers may have limits of their own.
    var isRefrain: Bool { baseURL == Self.refrain.baseURL }

    /// A bare host gets the usual `/v1`; a pasted full endpoint is used as is.
    var endpoint: URL? {
        guard var url = URL(string: baseURL) else { return nil }
        if url.path().isEmpty || url.path() == "/" { url.append(path: "v1") }
        if url.lastPathComponent != "transcriptions" { url.append(path: "audio/transcriptions") }
        return url
    }
}

/// Transcription settings, persisted in UserDefaults (API key in the Keychain).
enum TranscriptionSettings {
    static let baseURLKey = "transcription.baseURL"
    static let modelKey = "transcription.model"
    static let languageKey = "transcription.language"
    static let autoKey = "transcription.auto"

    static var service: TranscriptionService? {
        let defaults = UserDefaults.standard
        guard let baseURL = defaults.string(forKey: baseURLKey), !baseURL.isEmpty,
              let model = defaults.string(forKey: modelKey), !model.isEmpty
        else { return nil }
        return TranscriptionService(baseURL: baseURL, model: model)
    }

    /// Stored per server host, so switching services never sends a key to another host.
    static var apiKey: String? {
        get { Keychain.read(account: keyAccount) }
        set { Keychain.write(newValue, account: keyAccount) }
    }

    private static var keyAccount: String {
        let baseURL = UserDefaults.standard.string(forKey: baseURLKey) ?? ""
        return URL(string: baseURL)?.host() ?? baseURL
    }
}

/// `transcript.json`: what was said, phrase by phrase. `start` and `end` are seconds into the call;
/// `speaker` is "you" or "them", from the side it was heard on, or "1", "2"… for the voices a
/// service told apart; none when nothing tells who.
nonisolated struct Transcript: Codable {
    nonisolated struct Segment: Codable, Equatable {
        var speaker: String?
        var start: Double
        var end: Double
        var text: String
    }

    var segments: [Segment]

    /// For `transcript.txt`, which search, Copy and the shortcut after a call read: a paragraph each
    /// time the speaker changes, "You: …".
    var text: String {
        turns.map { turn in Self.name(of: turn.speaker).map { "\($0): \(turn.text)" } ?? turn.text }
            .joined(separator: "\n\n")
    }

    /// The phrases joined until the speaker changes, each turn from when it began.
    var turns: [(speaker: String?, start: Double, text: String)] {
        var turns: [(speaker: String?, start: Double, text: String)] = []
        for segment in segments {
            if let last = turns.last, last.speaker == segment.speaker {
                turns[turns.count - 1].text += " " + segment.text
            } else {
                turns.append((segment.speaker, segment.start, segment.text))
            }
        }
        return turns
    }

    static func name(of speaker: String?) -> String? {
        switch speaker {
        case "you": String(localized: "You")
        case "them": String(localized: "Others")
        case let number?: String(localized: "Speaker \(number)")
        case nil: nil
        }
    }
}

nonisolated enum Transcriber {
    /// The mix, as plain text.
    static func transcribe(
        _ audio: URL, service: TranscriptionService, apiKey: String?, language: String?,
        progress: @Sendable (Double) async -> Void
    ) async throws -> String {
        try await pieces(of: audio, as: .text, service: service, apiKey: apiKey, language: language, progress: progress)
            .map(\.text).joined(separator: " ")
    }

    /// The mix with who said what, from a service that tells voices apart: for a call without its
    /// sides. `nil` when it can't, or the call is too long for a cloud service to label.
    static func diarize(
        _ audio: URL, service: TranscriptionService, apiKey: String?, language: String?,
        progress: @Sendable (Double) async -> Void
    ) async throws -> Transcript? {
        do {
            let segments = try await pieces(of: audio, as: .diarized, service: service, apiKey: apiKey, language: language, progress: progress)
            return Transcript(segments: numbered(segments, alone: nil))
        } catch is Unsupported {
            return nil
        }
    }

    /// Each side on its own, with times: who said what, without guessing from voices, and within the
    /// others' side the voices a service tells apart. `nil` when the service doesn't time its text;
    /// the mix is transcribed instead.
    static func transcribe(
        you: URL, them: URL, service: TranscriptionService, apiKey: String?, language: String?,
        progress: @Sendable (Double) async -> Void
    ) async throws -> Transcript? {
        // The others may be several voices; you are one, so yours needs only times, unless the
        // service times its text only as it tells voices apart (gpt-4o-transcribe-diarize).
        guard let theirs = try await phrases(of: them, as: [.diarized, .timed], service: service, apiKey: apiKey, language: language, progress: { await progress($0 / 2) }),
              let mine = try await phrases(of: you, as: [.timed, .diarized], service: service, apiKey: apiKey, language: language, progress: { await progress(0.5 + $0 / 2) })
        else { return nil }
        return merge(you: mine, them: theirs)
    }

    /// The phrases of `audio` in the first of `formats` the service gives; `nil` when it gives none.
    private static func phrases(
        of audio: URL, as formats: [Format], service: TranscriptionService, apiKey: String?, language: String?,
        progress: @Sendable (Double) async -> Void
    ) async throws -> [Transcript.Segment]? {
        for format in formats {
            do {
                return try await pieces(of: audio, as: format, service: service, apiKey: apiKey, language: language, progress: progress)
            } catch is Unsupported {}
        }
        return nil
    }

    /// Both sides in the order they were said.
    static func merge(you: [Transcript.Segment], them: [Transcript.Segment]) -> Transcript {
        let mine = you.map { var segment = $0; segment.speaker = "you"; return segment }
        return Transcript(segments: (mine + numbered(them, alone: "them")).sorted { $0.start < $1.start })
    }

    /// The service's labels ("A", "SPEAKER_00"…) as "1", "2"… in the order the voices first speak.
    /// A single voice is `alone`.
    static func numbered(_ segments: [Transcript.Segment], alone: String?) -> [Transcript.Segment] {
        var voices: [String] = []
        for label in segments.compactMap(\.speaker) where !voices.contains(label) { voices.append(label) }
        return segments.map { segment in
            var segment = segment
            let number = segment.speaker.flatMap { voices.firstIndex(of: $0) }.map { String($0 + 1) }
            segment.speaker = voices.count > 1 ? number ?? alone : alone
            return segment
        }
    }

    /// What a request asks for: phrases with who said them (`diarized_json`, OpenAI's dialect for
    /// it), phrases with times (`verbose_json`), or text (`json`).
    private enum Format: String { case diarized = "diarized_json", timed = "verbose_json", text = "json" }

    /// Long recordings are split into 10-minute pieces to stay under the
    /// 25 MB / duration limits most providers enforce.
    private static let chunk: Double = 600

    /// The phrases of `audio`, timed from the start of the call; as text, a piece is one phrase.
    /// Off the main thread: each piece is read whole into the upload.
    @concurrent private static func pieces(
        of audio: URL, as format: Format, service: TranscriptionService, apiKey: String?, language: String?,
        progress: @Sendable (Double) async -> Void
    ) async throws -> [Transcript.Segment] {
        let asset = AVURLAsset(url: audio)
        let duration = try await asset.load(.duration).seconds
        // Voices keep their labels only within one request, so a call to diarize goes whole: to a
        // server on this Mac at any length, to a cloud service only when it's one piece anyway.
        if format == .diarized, duration > chunk, !service.isLocal { throw Unsupported() }
        let length = format == .diarized || service.isRefrain ? duration : chunk
        var phrases: [Transcript.Segment] = []
        var start: Double = 0
        repeat {
            await progress(start / max(duration, 1))
            let piece: URL
            // A WAV side goes as AAC too: ten times smaller, and what every service takes.
            if duration <= length, audio.pathExtension == "m4a" {
                piece = audio
            } else {
                piece = FileManager.default.temporaryDirectory.appending(path: "reprise-\(UUID().uuidString).m4a")
                guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                    throw Failure("Couldn't prepare the audio for upload.")
                }
                export.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                               duration: CMTime(seconds: min(length, duration - start), preferredTimescale: 600))
                try await export.export(to: piece, as: .m4a)
            }
            defer { if piece != audio { try? FileManager.default.removeItem(at: piece) } }
            // The tail of the previous piece keeps names and spelling consistent across chunks.
            let text = phrases.map(\.text).joined(separator: " ")
            let said = try await upload(piece, as: format, seconds: min(length, duration - start), service: service,
                                        apiKey: apiKey, language: language, prompt: String(text.suffix(400)))
            // To the millisecond: 600 + 12.34 would be 612.3399999999999 in the file.
            let time = { (($0 + start) * 1000).rounded() / 1000 }
            phrases += said.map { var segment = $0; segment.start = time($0.start); segment.end = time($0.end); return segment }
            start += length
        } while start < duration
        await progress(1)
        return phrases
    }

    private static func upload(
        _ file: URL, as format: Format, seconds: Double, service: TranscriptionService, apiKey: String?, language: String?, prompt: String
    ) async throws -> [Transcript.Segment] {
        guard let url = service.endpoint else {
            throw Failure("The server address isn't a valid URL.")
        }
        let boundary = "reprise-\(UUID().uuidString)"
        var request = URLRequest(url: url, timeoutInterval: max(900, seconds)) // a whole call to a server on this Mac
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", service.model)
        field("response_format", format.rawValue)
        if format == .diarized { field("chunking_strategy", "auto") } // OpenAI wants it past 30 seconds
        if let language, !language.isEmpty { field("language", language) }
        if !prompt.isEmpty { field("prompt", prompt) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8))
        body.append(try Data(contentsOf: file))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            // A service that can't time its text or tell voices apart turns the format down as a bad request.
            if format != .text, [400, 422].contains(status) { throw Unsupported() }
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error.message
                ?? String(data: data, encoding: .utf8)?.prefix(300).description
            throw Failure("The service answered \(status): \(message ?? String(localized: "no details")).")
        }
        let segments: [Transcript.Segment]
        if format == .text {
            segments = [.init(start: 0, end: 0, text: try JSONDecoder().decode(TextBody.self, from: data).text)]
        } else {
            guard let answer = try? JSONDecoder().decode(Transcript.self, from: data) else { throw Unsupported() } // without `segments`
            segments = answer.segments
        }
        return segments.map { var segment = $0; segment.text = $0.text.trimmingCharacters(in: .whitespacesAndNewlines); return segment }
            .filter { !$0.text.isEmpty }
    }

    private struct Unsupported: Error {}
    private struct TextBody: Decodable { let text: String }
    private struct ErrorBody: Decodable { struct Inner: Decodable { let message: String }; let error: Inner }
}

/// The API key lives in the login Keychain, never in preferences.
enum Keychain {
    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.nikiomori.reprise.transcription",
            kSecAttrAccount as String: account,
        ]
    }

    static func read(account: String) -> String? {
        var result: AnyObject?
        var query = query(account)
        query[kSecReturnData as String] = true
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String?, account: String) {
        SecItemDelete(query(account) as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var item = query(account)
        item[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
}
