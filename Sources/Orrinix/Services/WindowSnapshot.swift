import AppKit
import SwiftUI

/// `Orrinix --screenshot out.png` renders the menu window offscreen with
/// a real scan, so the README image is reproducible without clicking.
/// `--page <name>` renders a page of the full window instead (overview,
/// xcode, developer, apps, system, safari, largefiles, uninstaller,
/// settings), `--light` switches to the light appearance and
/// `--assume-access` hides the Full Disk Access banner.
@MainActor
enum WindowSnapshot {
    static func write(to path: String) async {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = appearance

        ScanModel.assumesFullDiskAccess = CommandLine.arguments.contains("--assume-access")
        let model = ScanModel(scansAutomatically: false)
        if !CommandLine.arguments.contains("--skip-scan") {
            await model.scan()
            // The Safari card scans on its own task; give it time to land.
            for _ in 0..<150 where model.safari.report == nil || model.safari.isScanning {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        render(model: model, to: path)
    }

    private static var isLight: Bool { CommandLine.arguments.contains("--light") }

    private static var appearance: NSAppearance? {
        NSAppearance(named: isLight ? .aqua : .darkAqua)
    }

    private static var requestedPage: AppPage? {
        guard let index = CommandLine.arguments.firstIndex(of: "--page"),
              CommandLine.arguments.indices.contains(index + 1) else { return nil }
        switch CommandLine.arguments[index + 1] {
        case "xcode": return .section(.xcode)
        case "developer": return .section(.developer)
        case "apps": return .section(.apps)
        case "system": return .section(.system)
        case "safari": return .safari
        case "largefiles": return .largeFiles
        case "uninstaller": return .uninstaller
        case "settings": return .settings
        default: return .overview
        }
    }

    /// Synchronous on purpose: pumping the run loop is not allowed from an
    /// async function, and SwiftUI needs a few turns to lay the list out.
    private static func render(model: ScanModel, to path: String) {
        let page = requestedPage
        let size = page == nil ? NSSize(width: 480, height: 740) : NSSize(width: 1040, height: 720)
        if let page { model.page = page }
        // The menu bar panel paints its own material; offscreen there is
        // none, so give the view an opaque window background to draw on.
        let root = Group {
            if page == nil {
                MenuView()
            } else {
                MainWindowView()
            }
        }
        .environment(model)
        .environment(\.colorScheme, isLight ? .light : .dark)
        .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = appearance
        let window = NSWindow(
            contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false
        )
        window.appearance = appearance
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        // Ordering the window in (offscreen, behind everything) makes AppKit
        // actually display it, which is what the layer-backed text needs.
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderBack(nil)

        for _ in 0..<(page == nil ? 8 : 16) {
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
        }

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            FileHandle.standardError.write(Data("could not create bitmap\n".utf8))
            return
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            print("wrote \(path) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        }
    }
}
