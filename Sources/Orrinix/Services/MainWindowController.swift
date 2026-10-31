import AppKit
import SwiftUI

/// Owns the full Orrinix window. It is an AppKit window rather than a SwiftUI
/// `Window` scene so it never opens on its own at launch (a menu bar app
/// should start silently) and so the Dock icon can follow it.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    static let shared = MainWindowController()

    private var window: NSWindow?

    func show(model: ScanModel, page: AppPage? = nil) {
        if let page { model.page = page }
        let window = window ?? makeWindow(model: model)
        self.window = window
        // A regular app while the window is open: Dock icon, Cmd-Tab, menus.
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeWindow(model: ScanModel) -> NSWindow {
        let hosting = NSHostingController(rootView: MainWindowView().environment(model))
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "Orrinix"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 820, height: 560)
        window.delegate = self
        window.setContentSize(NSSize(width: 1040, height: 720))
        if !window.setFrameUsingName("OrrinixMainWindow") {
            window.center()
        }
        window.setFrameAutosaveName("OrrinixMainWindow")
        return window
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
