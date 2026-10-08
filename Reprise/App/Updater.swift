import AppKit
import Security

/// Checks GitHub Releases for a newer Reprise and installs it in place of this copy.
@Observable final class Updater {
    static let shared = Updater()
    static let autoKey = "checkForUpdates"
    static let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    nonisolated struct Release: Decodable, Equatable, Sendable {
        let tag_name: String
        let html_url: URL
        let assets: [Asset]
        struct Asset: Decodable, Equatable, Sendable { let name: String; let browser_download_url: URL }

        var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
        /// Numeric, so 0.10 comes after 0.9.
        func isNewer(than version: String) -> Bool { self.version.compare(version, options: .numeric) == .orderedDescending }
    }

    enum State: Equatable {
        case idle, checking, upToDate, installing
        case available(Release)
        case failed(String, Release?)
    }

    private(set) var state = State.idle

    // ponytail: a sleeping task, once a day; NSBackgroundActivityScheduler if this ever needs to defer to battery.
    private init() {
        Task {
            while true {
                if UserDefaults.standard.bool(forKey: Self.autoKey) { await check(quietly: true) }
                try? await Task.sleep(for: .seconds(24 * 60 * 60))
            }
        }
    }

    /// Quietly: a background check that says nothing unless there is an update.
    func check(quietly: Bool = false) async {
        guard state != .checking, state != .installing else { return }
        if !quietly { state = .checking }
        do {
            let release = try await Self.latest()
            state = release.isNewer(than: Self.current) ? .available(release) : quietly ? state : .upToDate
        } catch {
            log.error("Update check failed: \(error.localizedDescription, privacy: .public)")
            if !quietly { state = .failed(error.localizedDescription, nil) }
        }
    }

    func install(_ release: Release) {
        guard state != .installing else { return }
        state = .installing
        Task {
            do {
                guard let zip = release.assets.first(where: { $0.name.hasSuffix(".zip") }) else {
                    throw Failure(errorDescription: "This release has no app to download.")
                }
                let folder = try await Self.download(zip.browser_download_url)
                defer { try? FileManager.default.removeItem(at: folder) }
                let app = folder.appending(path: "Reprise.app")
                try await Task.detached { try Self.verify(app) }.value
                // Relaunching would cut a call that started during the download short.
                guard AppModel.shared.session == nil else { throw Failure(errorDescription: "Finish the recording, then install the update.") }
                _ = try FileManager.default.replaceItemAt(Bundle.main.bundleURL, withItemAt: app)
                log.notice("Updated to \(release.version, privacy: .public), relaunching")
                relaunch()
            } catch {
                log.error("Update failed: \(error.localizedDescription, privacy: .public)")
                state = .failed(error.localizedDescription, release)
            }
        }
    }

    private nonisolated static func latest() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/nikiomori/reprise/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // A session of its own, gone with its connections once the answer is in: the shared one
        // kept them, and a cache, for the rest of the day. 0.5 MB of a menu bar app waiting for calls.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure(errorDescription: "GitHub answered \(status). Try again later.") }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    /// Unpacked next to this copy, on the same volume, so the swap is a rename.
    /// Off the main thread: it waits for ditto to unpack the whole app.
    @concurrent private nonisolated static func download(_ url: URL) async throws -> URL {
        let (zip, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: zip) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(errorDescription: "The download failed. Try again later.") }
        let folder = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: Bundle.main.bundleURL, create: true)
        // ditto, not unzip: it puts the extended attributes back, which the signature covers.
        let ditto = Process()
        ditto.executableURL = URL(filePath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, folder.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw Failure(errorDescription: "Couldn't unpack the update.") }
        return folder
    }

    /// Only an app with this copy's signature — same developer, same bundle ID — may replace it.
    /// A build from the source code has its own signature, so it never takes a release.
    private nonisolated static func verify(_ app: URL) throws {
        var current: SecStaticCode?, update: SecStaticCode?, requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &current) == errSecSuccess, let current,
              SecCodeCopyDesignatedRequirement(current, [], &requirement) == errSecSuccess,
              SecStaticCodeCreateWithPath(app as CFURL, [], &update) == errSecSuccess, let update,
              SecStaticCodeCheckValidity(update, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode), requirement) == errSecSuccess
        else { throw Failure(errorDescription: "The download doesn't have the signature of this copy of Reprise. Download the update from GitHub.") }
    }
}
