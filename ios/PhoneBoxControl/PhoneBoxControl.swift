import AppIntents
import SwiftUI
import WidgetKit

/// Control Center › Add a Control › PhoneBox (iOS 18): tapping it opens the panel, like the Quick Settings tile on
/// Android (Edit tiles › PhoneBox).
@main
struct PhoneBoxControls: WidgetBundle {
    var body: some Widget {
        PanelControl()
    }
}

struct PanelControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "net.oxog.phonebox.deskpanel.open") {
            ControlWidgetButton(action: OpenPanelIntent()) {
                Label("PhoneBox", systemImage: "display")
            }
        }
        .displayName("PhoneBox")
        .description("Opens the desk panel.")
    }
}
