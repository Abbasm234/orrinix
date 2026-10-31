import AppKit
import Foundation
import Observation

struct InstalledApp: Identifiable, Equatable, Sendable {
    let url: URL
    let name: String
    let bundleID: String
    let version: String?
    let bytes: Int64

    var id: String { url.path }
}

/// A file or folder an app left outside its bundle.
struct AppLeftover: Identifiable, Equatable, Sendable {
    enum Match: Sendable {
        /// Named after the bundle identifier: certainly the app's.
        case bundleID
        /// Named after the app: very likely, but worth a look.
        case name
    }

    let url: URL
    let bytes: Int64
    let kind: String
    let match: Match

    var id: String { url.path }
}

enum AppUninstaller {
    private static let appRoots: [URL] = [
        URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/Applications/Utilities"), .home("Applications"),
    ]

    /// Third-party apps in the usual install locations, including apps one
    /// folder down (Microsoft Office, Adobe). Apple's own apps are left out.
    static func installedApps() async -> [InstalledApp] {
        await Task.detached(priority: .utility) {
            var bundles: [URL] = []
            for root in appRoots {
                for entry in root.children() {
                    if entry.pathExtension == "app" {
                        bundles.append(entry)
                    } else if entry.isDirectory, entry.lastPathComponent != "Utilities" {
                        bundles += entry.children().filter { $0.pathExtension == "app" }
                    }
                }
            }
            let ownID = Bundle.main.bundleIdentifier
            return bundles.compactMap { url -> InstalledApp? in
                guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier,
                      !bundleID.hasPrefix("com.apple."), bundleID != ownID else { return nil }
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                return InstalledApp(
                    url: url, name: name, bundleID: bundleID,
                    version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                    bytes: DiskSize.allocatedSync(at: url)
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }.value
    }

    /// Everything in the standard Library locations that belongs to `app`.
    static func leftovers(for app: InstalledApp) async -> [AppLeftover] {
        await Task.detached(priority: .utility) {
            var found: [String: AppLeftover] = [:]
            let id = app.bundleID
            let names = Set([app.name, app.url.deletingPathExtension().lastPathComponent])

            func add(_ url: URL, _ kind: String, _ match: AppLeftover.Match) {
                guard url.exists, found[url.path] == nil else { return }
                found[url.path] = AppLeftover(url: url, bytes: max(DiskSize.allocatedSync(at: url), 1), kind: kind, match: match)
            }

            /// Children of `folder` whose name contains the bundle id, e.g.
            /// "com.foo.app.plist", "TEAMID.com.foo.app", "com.foo.app.helper".
            func byID(_ folder: URL, _ kind: String) {
                for child in folder.children(includeHidden: true) where child.lastPathComponent.contains(id) {
                    add(child, kind, .bundleID)
                }
            }

            func byName(_ folder: URL, _ kind: String) {
                for name in names { add(folder.appending(path: name), kind, .name) }
            }

            let library = URL.home("Library")
            byID(library.appending(path: "Application Support"), L("App data"))
            byName(library.appending(path: "Application Support"), L("App data"))
            byID(library.appending(path: "Caches"), L("Cache"))
            byName(library.appending(path: "Caches"), L("Cache"))
            byID(library.appending(path: "Containers"), L("Sandbox container"))
            byID(library.appending(path: "Group Containers"), L("Shared container"))
            byID(library.appending(path: "Application Scripts"), L("Scripts"))
            byID(library.appending(path: "Preferences"), L("Preferences"))
            byID(library.appending(path: "Preferences/ByHost"), L("Preferences"))
            byID(library.appending(path: "Saved Application State"), L("Window state"))
            byID(library.appending(path: "HTTPStorages"), L("Web storage"))
            byID(library.appending(path: "WebKit"), L("Web storage"))
            byID(library.appending(path: "Cookies"), L("Cookies"))
            byID(library.appending(path: "Logs"), L("Logs"))
            byName(library.appending(path: "Logs"), L("Logs"))
            byID(library.appending(path: "LaunchAgents"), L("Login item"))

            let system = URL(fileURLWithPath: "/Library")
            byID(system.appending(path: "LaunchAgents"), L("Login item"))
            byID(system.appending(path: "LaunchDaemons"), L("Background service"))
            byID(system.appending(path: "PrivilegedHelperTools"), L("Privileged helper"))
            byID(system.appending(path: "Application Support"), L("App data"))
            byName(system.appending(path: "Application Support"), L("App data"))
            byID(system.appending(path: "Caches"), L("Cache"))
            byID(system.appending(path: "Preferences"), L("Preferences"))

            return found.values.sorted { $0.bytes > $1.bytes }
        }.value
    }

    /// Containers and bundle-id-named folders whose app is no longer
    /// installed. LaunchServices is asked about the id and each of its
    /// parents, so an extension's container counts as long as its app exists.
    @MainActor
    static func orphans() async -> [AppLeftover] {
        let candidates: [(URL, String)] = await Task.detached(priority: .utility) {
            var list: [(URL, String)] = []
            for (folder, kind) in [
                (URL.home("Library/Containers"), L("Sandbox container")),
                (URL.home("Library/Application Support"), L("App data")),
                (URL.home("Library/Caches"), L("Cache")),
            ] {
                for child in folder.children() where child.isDirectory && looksLikeBundleID(child.lastPathComponent) {
                    list.append((child, kind))
                }
            }
            return list
        }.value

        var orphaned: [(URL, String)] = []
        for (url, kind) in candidates where !isInstalled(url.lastPathComponent) {
            orphaned.append((url, kind))
        }
        return await Task.detached(priority: .utility) {
            orphaned.compactMap { url, kind -> AppLeftover? in
                let bytes = DiskSize.allocatedSync(at: url)
                guard bytes >= ProbeSupport.megabyte else { return nil }
                return AppLeftover(url: url, bytes: bytes, kind: kind, match: .bundleID)
            }
            .sorted { $0.bytes > $1.bytes }
        }.value
    }

    static func looksLikeBundleID(_ name: String) -> Bool {
        let parts = name.split(separator: ".")
        guard parts.count >= 3, !name.hasPrefix("com.apple.") else { return false }
        return ["com", "org", "net", "io", "app", "co", "dev", "de", "us", "me"].contains(String(parts[0]))
    }

    @MainActor
    private static func isInstalled(_ bundleID: String) -> Bool {
        var parts = bundleID.split(separator: ".").map(String.init)
        while parts.count >= 2 {
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: parts.joined(separator: ".")) != nil {
                return true
            }
            parts.removeLast()
        }
        return false
    }
}

@MainActor
@Observable
final class UninstallerModel {
    private(set) var apps: [InstalledApp] = []
    private(set) var isLoadingApps = false
    private(set) var leftovers: [AppLeftover] = []
    private(set) var isLoadingLeftovers = false
    private(set) var orphans: [AppLeftover] = []
    private(set) var isLoadingOrphans = false
    private(set) var isRemoving = false
    var selectedApp: InstalledApp? {
        didSet {
            guard selectedApp != oldValue else { return }
            Task { await loadLeftovers() }
        }
    }
    /// Paths ticked for removal: leftovers of the selected app, or orphans.
    var checkedPaths: Set<String> = []
    var removesAppBundle = true
    var errorMessage: String?
    var notice: String?

    func loadApps() async {
        guard !isLoadingApps else { return }
        isLoadingApps = true
        apps = await AppUninstaller.installedApps()
        isLoadingApps = false
    }

    func loadLeftovers() async {
        guard let app = selectedApp else {
            leftovers = []
            return
        }
        isLoadingLeftovers = true
        removesAppBundle = true
        let found = await AppUninstaller.leftovers(for: app)
        guard selectedApp == app else { return }
        leftovers = found
        // Bundle-id matches are certain; name matches stay unticked until
        // the user has looked at them.
        checkedPaths = Set(found.filter { $0.match == .bundleID }.map(\.id))
        isLoadingLeftovers = false
    }

    func loadOrphans() async {
        guard !isLoadingOrphans else { return }
        isLoadingOrphans = true
        orphans = await AppUninstaller.orphans()
        isLoadingOrphans = false
    }

    func toggle(_ leftover: AppLeftover) {
        if checkedPaths.contains(leftover.id) { checkedPaths.remove(leftover.id) } else { checkedPaths.insert(leftover.id) }
    }

    var checkedLeftovers: [AppLeftover] {
        leftovers.filter { checkedPaths.contains($0.id) }
    }

    var checkedOrphans: [AppLeftover] {
        orphans.filter { checkedPaths.contains($0.id) }
    }

    var uninstallBytes: Int64 {
        checkedLeftovers.reduce(removesAppBundle ? (selectedApp?.bytes ?? 0) : 0) { $0 + $1.bytes }
    }

    /// Quits the app, then moves it and the ticked leftovers to the Trash.
    /// Returns the bytes the volume released.
    func uninstall() async -> Int64 {
        guard let app = selectedApp else { return 0 }
        var urls = checkedLeftovers.map(\.url)
        if removesAppBundle { urls.insert(app.url, at: 0) }
        guard !urls.isEmpty else { return 0 }
        let released = await remove(urls, quitting: app.bundleID)
        if removesAppBundle, !app.url.exists {
            apps.removeAll { $0.id == app.id }
            selectedApp = nil
            notice = L("%@ moved to the Trash.", app.name)
        } else {
            await loadLeftovers()
        }
        return released
    }

    func removeCheckedOrphans() async -> Int64 {
        let chosen = checkedOrphans
        let released = await remove(chosen.map(\.url), quitting: nil)
        orphans.removeAll { !$0.url.exists }
        checkedPaths.subtract(chosen.map(\.id))
        return released
    }

    private func remove(_ urls: [URL], quitting bundleID: String?) async -> Int64 {
        isRemoving = true
        defer { isRemoving = false }
        errorMessage = nil
        notice = nil
        if let bundleID {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            running.forEach { $0.terminate() }
            for _ in 0..<10 where running.contains(where: { !$0.isTerminated }) {
                try? await Task.sleep(for: .milliseconds(500))
            }
            if running.contains(where: { !$0.isTerminated }) {
                errorMessage = L("Quit %@ first, then try again.", selectedApp?.name ?? bundleID)
                return 0
            }
        }
        let before = DiskSize.metrics().physicalFreeBytes
        do {
            try await Reclaimer.perform(.removePaths(urls), preferTrash: true)
        } catch {
            errorMessage = error.localizedDescription
        }
        return max(DiskSize.metrics().physicalFreeBytes - before, 0)
    }
}
