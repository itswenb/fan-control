import AppKit
import Combine
import Sparkle

@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    private let controller: SPUStandardUpdaterController

    init(startingUpdater: Bool = true) {
        controller = SPUStandardUpdaterController(startingUpdater: startingUpdater, updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    func checkForUpdates() {
        AppWindowVisibility.prepareToOpen()
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}
