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
        _model = State(initialValue: ScanModel(scansAutomatically: headlessMode == nil))

        // Menu bar only: no Dock icon, no main window.
        NSApplication.shared.setActivationPolicy(.accessory)
        // A MenuBarExtra has no conventional visible window, so macOS can
        // otherwise automatically terminate it after the initial scan. Keep
        // the utility resident until the user explicitly chooses Quit.
        ProcessInfo.processInfo.automaticTerminationSupportEnabled = true
        ProcessInfo.processInfo.disableAutomaticTermination("Orrinix must remain available from the menu bar.")

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

    /// Drive glyph plus the size of known storage locations found by Orrinix.
    /// macOS Storage uses its own categories and updates them asynchronously,
    /// so this intentionally is not presented as its exact System Data total.
    private var menuBarLabel: some View {
        HStack(spacing: 3) {
            Image(systemName: "internaldrive")
            if model.measuredBytes >= 100 * ProbeSupport.megabyte {
                Text(model.measuredBytes.byteString)
                    .monospacedDigit()
            }
        }
        .help(L("System Data found: %@", model.measuredBytes.byteString))
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
