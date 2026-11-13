import MeterUI
import SwiftUI

@main
struct MeterApp: App {
    @State private var model: AppModel

    init() {
        let m = AppModel.bootstrap()
        _model = State(initialValue: m)
        Task { await m.start() }
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverRoot().environment(model)
        } label: {
            MenuBarLabelView(title: model.popover.title)
        }
        .menuBarExtraStyle(.window)

        Window("Meter", id: MeterWindowID.main) {
            MainWindowRoot().environment(model)
        }
        .defaultSize(width: 1040, height: 700)

        Settings {
            SettingsRoot().environment(model)
        }
    }
}
