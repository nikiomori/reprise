import AVFoundation
import Security

/// Any service that speaks the OpenAI `POST /audio/transcriptions` dialect:
/// OpenAI, Groq, Mistral, or a local whisper server (speaches, whisper.cpp, LocalAI…).
nonisolated struct TranscriptionService: Sendable {
    var baseURL: String
    var model: String

    static let presets: [(name: String, service: TranscriptionService)] = [
        ("OpenAI", .init(baseURL: "https://api.openai.com/v1", model: "gpt-4o-transcribe")),
        ("Groq", .init(baseURL: "https://api.groq.com/openai/v1", model: "whisper-large-v3-turbo")),
        ("Mistral", .init(baseURL: "https://api.mistral.ai/v1", model: "voxtral-mini-latest")),
        ("Local server", .init(baseURL: "http://localhost:8000/v1", model: "Systran/faster-whisper-large-v3")),
    ]
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

nonisolated enum Transcriber {
    /// Long recordings are split into 10-minute pieces to stay under the
    /// 25 MB / duration limits most providers enforce.
    static func transcribe(
        _ audio: URL, service: TranscriptionService, apiKey: String?, language: String?,
        progress: @Sendable (Double) async -> Void
    ) async throws -> String {
        let asset = AVURLAsset(url: audio)
        let duration = try await asset.load(.duration).seconds
        let chunk: Double = 600
        var text = ""
        var start: Double = 0
        repeat {
            await progress(start / max(duration, 1))
            let piece: URL
            if duration <= chunk {
                piece = audio
            } else {
                piece = FileManager.default.temporaryDirectory.appending(path: "reprise-\(UUID().uuidString).m4a")
                guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                    throw Failure(errorDescription: "Couldn't prepare the audio for upload.")
                }
                export.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                               duration: CMTime(seconds: min(chunk, duration - start), preferredTimescale: 600))
                try await export.export(to: piece, as: .m4a)
            }
            defer { if piece != audio { try? FileManager.default.removeItem(at: piece) } }
            // The tail of the previous piece keeps names and spelling consistent across chunks.
            let part = try await upload(piece, service: service, apiKey: apiKey, language: language, prompt: String(text.suffix(400)))
            text += (text.isEmpty ? "" : " ") + part.trimmingCharacters(in: .whitespacesAndNewlines)
            start += chunk
        } while start < duration
        await progress(1)
        return text
    }

    private static func upload(_ file: URL, service: TranscriptionService, apiKey: String?, language: String?, prompt: String) async throws -> String {
        guard let url = URL(string: service.baseURL)?.appending(path: "audio/transcriptions") else {
            throw Failure(errorDescription: "The server address isn't a valid URL.")
        }
        let boundary = "reprise-\(UUID().uuidString)"
        var request = URLRequest(url: url, timeoutInterval: 900)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", service.model)
        field("response_format", "json")
        if let language, !language.isEmpty { field("language", language) }
        if !prompt.isEmpty { field("prompt", prompt) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8))
        body.append(try Data(contentsOf: file))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error.message
                ?? String(data: data, encoding: .utf8)?.prefix(300).description
            throw Failure(errorDescription: "The service answered \(status): \(message ?? "no details").")
        }
        return try JSONDecoder().decode(TextBody.self, from: data).text
    }

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
