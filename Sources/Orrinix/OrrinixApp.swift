import AppKit
import SwiftUI

@main
struct OrrinixApp: App {
    @NSApplicationDelegateAdaptor(PowerOffGuard.self) private var powerOffGuard
    @State private var model: ScanModel
    private let headlessMode: HeadlessMode?

    init() {
        let headlessMode = Self.headlessMode(from: CommandLine.arguments)
        self.headlessMode = headlessMode
        let model = ScanModel(scansAutomatically: headlessMode == nil)
        _model = State(initialValue: model)

        // Menu bar only: no Dock icon, no main window.
        NSApplication.shared.setActivationPolicy(.accessory)
        // A MenuBarExtra has no conventional visible window, so macOS can
        // otherwise automatically terminate it after the initial scan. Keep
        // the utility resident until the user explicitly chooses Quit.
        ProcessInfo.processInfo.automaticTerminationSupportEnabled = true
        ProcessInfo.processInfo.disableAutomaticTermination("Orrinix must remain available from the menu bar.")

        // `--window` opens the full window at launch, for development.
        if headlessMode == nil, CommandLine.arguments.contains("--window") {
            // SwiftUI creates the App during launch; wait for the run loop.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { MainWindowController.shared.show(model: model) }
            }
        }

        if let headlessMode {
            Task {
                switch headlessMode {
                case .json:
                    await JSONInventory.write(to: FileHandle.standardOutput)
                case .screenshot(let path):
                    await WindowSnapshot.write(to: path)
                }
                NSApplication.shared.terminate(nil)
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environment(model)
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.window)
    }

    /// The menu bar and dashboard both read the same volume-level metric.
    private var menuBarLabel: some View {
        HStack(spacing: 3) {
            Image(systemName: "internaldrive")
            Text(model.storageMetrics.physicalFreeBytes.byteString)
                .monospacedDigit()
        }
        .help(L("Free now: %@ · Potentially reclaimable: %@",
                model.storageMetrics.physicalFreeBytes.byteString,
                model.storageMetrics.estimatedReclaimableBytes?.byteString ?? L("Unavailable")))
    }

    private enum HeadlessMode {
        case json
        case screenshot(String)
    }

    private static func headlessMode(from arguments: [String]) -> HeadlessMode? {
        if arguments.contains("--json") { return .json }
        if let index = arguments.firstIndex(of: "--screenshot"), arguments.indices.contains(index + 1) {
            return .screenshot(arguments[index + 1])
        }
        return nil
    }
}
