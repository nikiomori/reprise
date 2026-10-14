import AppIntents
import AppKit
import CoreSpotlight

// Spotlight, Shortcuts and Siri pick these up on their own. A shortcut built from one can
// also get a keyboard shortcut in the Shortcuts app — a global hotkey without any code here.

nonisolated struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Recording"
    static let description = IntentDescription("Records the call going on, or your microphone and the sound of the Mac.")

    func perform() async throws -> some IntentResult {
        await AppModel.shared.record()
        return .result()
    }
}

nonisolated struct StopRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Recording"
    static let description = IntentDescription("Stops the recording and saves it.")

    func perform() async throws -> some IntentResult {
        await AppModel.shared.stopRecording()
        return .result()
    }
}

nonisolated struct MarkMomentIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark This Moment"
    static let description = IntentDescription("Marks this moment of the call being recorded, to find it on the call's wave later.")

    func perform() async throws -> some IntentResult {
        await AppModel.shared.mark()
        return .result()
    }
}

nonisolated struct CopyLastCallIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy the Last Call"
    static let description = IntentDescription("Copies the last call's transcript with details: its title and date, when each turn began, its marks and the folder of its files. A shortcut can also pass the text on.")

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let model = AppModel.shared
        guard let last = model.store.recordings.first(where: { !model.isLive($0) }) else { throw Failure("There are no saved calls yet.") }
        let brief = model.store.brief(of: last)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(brief, forType: .string)
        return .result(value: brief)
    }
}

/// A call as Spotlight, Shortcuts and Siri see it. Spotlight finds it by its title, the people
/// invited and what was said; Shortcuts gets a Find Calls action and each of these properties.
struct CallEntity: IndexedEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Call"
    static let defaultQuery = CallQuery()

    let id: String
    @Property(title: "Title") var title: String
    @Property(title: "Date") var date: Date
    @Property(title: "Duration") var duration: Measurement<UnitDuration>
    @Property(title: "App") var app: String
    @Property(title: "Participants") var participants: [String]
    @Property(title: "Transcript") var transcript: String
    @Property(title: "Folder") var folder: URL
    /// "Zoom · 6 Oct 2026 at 21:30 · 42:05", made where the formatters live.
    private let subtitle: String

    @MainActor init(_ recording: Recording, transcript: String?) {
        id = recording.id
        subtitle = [recording.app?.name ?? String(localized: "Recording"), recording.startedAt.formatted(date: .abbreviated, time: .shortened), recording.duration.clock].joined(separator: " · ")
        title = recording.title
        date = recording.startedAt
        duration = Measurement(value: recording.duration, unit: .seconds)
        app = recording.app?.name ?? String(localized: "Recording")
        participants = recording.participants ?? []
        self.transcript = transcript ?? ""
        folder = recording.folder
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)", image: .init(systemName: "waveform"))
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let item = defaultAttributeSet
        item.displayName = title
        item.contentDescription = subtitle
        item.participants = participants
        item.contentCreationDate = date
        item.duration = NSNumber(value: duration.value)
        if !transcript.isEmpty { item.transcribedTextContent = transcript }
        return item
    }
}

/// Each entity reads its call's transcript, so only the calls asked for become entities: Spotlight
/// opening one call read the whole library's.
nonisolated struct CallQuery: EnumerableEntityQuery, EntityStringQuery {
    @MainActor func entities(for identifiers: [CallEntity.ID]) async throws -> [CallEntity] {
        entities(saved.filter { identifiers.contains($0.id) })
    }

    @MainActor func entities(matching string: String) async throws -> [CallEntity] {
        entities(saved).filter { [$0.title, $0.transcript].contains { $0.localizedStandardContains(string) } || $0.participants.contains { $0.localizedStandardContains(string) } }
    }

    @MainActor func suggestedEntities() async throws -> [CallEntity] { entities(Array(saved.prefix(10))) }

    @MainActor func allEntities() async throws -> [CallEntity] { entities(saved) }

    /// Newest first: a call still being recorded has nothing to open or read yet.
    @MainActor private var saved: [Recording] {
        let model = AppModel.shared
        return model.store.recordings.filter { !model.isLive($0) }
    }

    @MainActor private func entities(_ recordings: [Recording]) -> [CallEntity] { recordings.map(AppModel.shared.store.entity) }
}

/// Opens a call in the library: from Spotlight, or from a shortcut.
struct OpenCallIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Call"
    static let description = IntentDescription("Opens the call in Reprise's library.")

    @Parameter(title: "Call") var target: CallEntity

    @MainActor func perform() async throws -> some IntentResult {
        AppModel.shared.selection = target.id
        NotificationCenter.default.post(name: .openRepriseWindow, object: "library")
        return .result()
    }
}

nonisolated struct RepriseShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: ["Start recording with \(.applicationName)", "Record a call with \(.applicationName)"],
            shortTitle: "Start Recording",
            systemImageName: "record.circle"
        )
        AppShortcut(
            intent: StopRecordingIntent(),
            phrases: ["Stop recording with \(.applicationName)"],
            shortTitle: "Stop Recording",
            systemImageName: "stop.circle"
        )
        AppShortcut(
            intent: MarkMomentIntent(),
            phrases: ["Mark this moment with \(.applicationName)", "Mark the call with \(.applicationName)"],
            shortTitle: "Mark This Moment",
            systemImageName: "flag"
        )
        AppShortcut(
            intent: CopyLastCallIntent(),
            phrases: ["Copy the last call with \(.applicationName)"],
            shortTitle: "Copy the Last Call",
            systemImageName: "doc.on.doc"
        )
    }
}
