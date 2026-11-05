import AppKit
import UniformTypeIdentifiers

/// Share › Reprise: hands the shared sound files and movies to Reprise, which adds them to its library
/// and transcribes them, as when they're opened with it. No sheet of its own: there's nothing to choose.
final class ShareViewController: NSViewController {
    override func loadView() { view = NSView(frame: .zero) }

    override func viewDidLoad() {
        guard let context = extensionContext else { return }
        let providers = (context.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.audiovisualContent.identifier) }
        Task {
            var files: [URL] = []
            for provider in providers { if let file = await Self.file(of: provider) { files.append(file) } }
            // Reprise.app/Contents/PlugIns/RepriseShare.appex
            let reprise = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            do { if !files.isEmpty { try await NSWorkspace.shared.open(files, withApplicationAt: reprise, configuration: .init()) } }
            catch { return context.cancelRequest(withError: error) }
            context.completeRequest(returningItems: nil)
        }
    }

    // ponytail: a copy stays in the extension's temporary folder until macOS clears it (3 days unused).
    /// The file itself, as Finder shares it; else a copy of the sound handed over, as by an app sharing
    /// its own recording, which is gone once the handler returns.
    private static func file(of provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { done in
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
                _ = provider.loadFileRepresentation(for: .audiovisualContent) { url, _, _ in
                    guard let url else { return done.resume(returning: nil) }
                    // Under the name it was shared with, the call's title, not the one the copy was given.
                    let name = provider.suggestedName.map { ($0 as NSString).pathExtension.isEmpty ? "\($0).\(url.pathExtension)" : $0 }
                    let copy = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
                        .appending(path: name ?? url.lastPathComponent)
                    try? FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                    done.resume(returning: (try? FileManager.default.copyItem(at: url, to: copy)) == nil ? nil : copy)
                }
                return
            }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                done.resume(returning: item as? URL ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) })
            }
        }
    }
}
