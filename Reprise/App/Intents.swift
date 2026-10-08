import AppIntents

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
    }
}
