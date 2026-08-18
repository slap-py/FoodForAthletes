import AppIntents
import SwiftUI
import WidgetKit

@main
struct DayplateControlsBundle: WidgetBundle {
    var body: some Widget {
        LogFoodControl()
    }
}

struct LogFoodControl: ControlWidget {
    static let kind = "com.dayplate.log-food"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenURLIntent(URL(string: "dayplate://log")!)) {
                Label("Log food", systemImage: "fork.knife")
            }
        }
        .displayName("Log food")
        .description("Open Dayplate and choose how to log. No entry is created automatically.")
    }
}
