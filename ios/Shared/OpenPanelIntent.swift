import AppIntents

/// Brings the panel to the front: the action of the Control Center control (Android's Quick Settings tile, PanelTile.kt).
/// It only opens the app, so it has no state of its own. Compiled into the app and the control extension.
@available(iOS 16.0, *)
struct OpenPanelIntent: AppIntent {
    static var title: LocalizedStringResource = "Open PhoneBox"
    static var description = IntentDescription("Opens the PhoneBox desk panel.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult { .result() }
}
