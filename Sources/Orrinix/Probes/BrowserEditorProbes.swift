import Foundation

// MARK: - Browsers

/// Chromium-family browsers keep a disk cache under ~/Library/Caches plus
/// code, GPU and service-worker caches inside every profile. All of it is
/// rebuilt while browsing; history, logins and bookmarks are never touched.
struct BrowserProbe: StorageProbe {
    private struct Browser {
        let id: String
        let name: String
        let bundleIDs: [String]
        /// Profile root under ~/Library/Application Support.
        let support: String
        /// Folders under ~/Library/Caches.
        let caches: [String]
    }

    private static let chromium: [Browser] = [
        Browser(id: "chrome", name: "Chrome", bundleIDs: ["com.google.Chrome"],
                support: "Google/Chrome", caches: ["Google/Chrome", "com.google.Chrome"]),
        Browser(id: "edge", name: "Microsoft Edge", bundleIDs: ["com.microsoft.edgemac"],
                support: "Microsoft Edge", caches: ["Microsoft Edge", "com.microsoft.edgemac"]),
        Browser(id: "brave", name: "Brave", bundleIDs: ["com.brave.Browser"],
                support: "BraveSoftware/Brave-Browser", caches: ["BraveSoftware/Brave-Browser", "com.brave.Browser"]),
        Browser(id: "arc", name: "Arc", bundleIDs: ["company.thebrowser.Browser"],
                support: "Arc/User Data", caches: ["Arc", "company.thebrowser.Browser"]),
        Browser(id: "vivaldi", name: "Vivaldi", bundleIDs: ["com.vivaldi.Vivaldi"],
                support: "Vivaldi", caches: ["Vivaldi", "com.vivaldi.Vivaldi"]),
        Browser(id: "opera", name: "Opera", bundleIDs: ["com.operasoftware.Opera"],
                support: "com.operasoftware.Opera", caches: ["com.operasoftware.Opera"]),
        Browser(id: "chromium", name: "Chromium", bundleIDs: ["org.chromium.Chromium"],
                support: "Chromium", caches: ["Chromium", "org.chromium.Chromium"]),
    ]

    /// Cache folders inside each Chromium profile.
    private static let profileCaches = [
        "Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache",
        "Service Worker/CacheStorage", "Service Worker/ScriptCache",
    ]
    /// Cache folders at the top of the profile root, shared by all profiles.
    private static let sharedCaches = ["GrShaderCache", "ShaderCache", "GraphiteDawnCache", "component_crx_cache"]

    /// Top-level folders this probe owns, so `AppDataProbe` does not list
    /// them a second time as generic app data.
    static let coveredAppSupport: Set<String> = [
        "Microsoft Edge", "BraveSoftware", "Arc", "Vivaldi", "com.operasoftware.Opera", "Chromium", "Firefox",
    ]
    static let coveredCaches: Set<String> = [
        "Google", "com.google.Chrome", "Microsoft Edge", "com.microsoft.edgemac", "BraveSoftware", "com.brave.Browser",
        "Arc", "company.thebrowser.Browser", "Vivaldi", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
        "Chromium", "org.chromium.Chromium", "Firefox",
    ]

    func probe() async -> [StorageItem] {
        var items: [StorageItem] = []

        for browser in Self.chromium {
            let quit = ReclaimAction.requireQuit(bundleIDs: browser.bundleIDs, appName: browser.name)

            let diskCaches = browser.caches.map { URL.home("Library/Caches/\($0)") }.filter(\.exists)
            if !diskCaches.isEmpty {
                var total: Int64 = 0
                for folder in diskCaches { total += await DiskSize.allocated(at: folder) }
                if total >= ProbeSupport.megabyte {
                    items.append(StorageItem(
                        id: "browser-\(browser.id)-cache", category: .browsers, name: "\(browser.name) cache",
                        detail: "Downloaded pages, images and scripts. Rebuilt as you browse. Quit \(browser.name) first.",
                        sizeBytes: total, safety: .safe,
                        action: .steps([quit, .emptyDirectories(diskCaches)]), revealURL: diskCaches[0],
                        alsoClaims: Array(diskCaches.dropFirst())
                    ))
                }
            }

            let support = URL.home("Library/Application Support/\(browser.support)")
            let profiles = support.children().filter {
                let name = $0.lastPathComponent
                return name == "Default" || name.hasPrefix("Profile ") || name == "Guest Profile" || name == "System Profile"
            }
            let folders = (profiles.flatMap { profile in Self.profileCaches.map { profile.appending(path: $0) } }
                + Self.sharedCaches.map { support.appending(path: $0) })
                .filter(\.exists)
            if !folders.isEmpty {
                var total: Int64 = 0
                for folder in folders { total += await DiskSize.allocated(at: folder) }
                if total >= ProbeSupport.megabyte {
                    let profileCount = profiles.count
                    items.append(StorageItem(
                        id: "browser-\(browser.id)-profile-caches", category: .browsers,
                        name: "\(browser.name) code & service worker caches",
                        detail: "Compiled scripts, GPU shaders and offline web-app caches across \(profileCount) profile\(profileCount == 1 ? "" : "s"). History, logins and bookmarks stay.",
                        sizeBytes: total, safety: .safe,
                        // Reveal one cache folder rather than the profile, so the
                        // catch-all still sees the rest of the profile.
                        action: .steps([quit, .emptyDirectories(folders)]), revealURL: folders[0]
                    ))
                }
            }
        }

        let firefoxCache = URL.home("Library/Caches/Firefox")
        if let item = await ProbeSupport.directoryItem(
            id: "browser-firefox-cache", category: .browsers, name: "Firefox cache",
            detail: "Network cache for every Firefox profile. Rebuilt as you browse. Quit Firefox first.",
            url: firefoxCache, safety: .safe,
            action: .steps([.requireQuit(bundleIDs: ["org.mozilla.firefox"], appName: "Firefox"), .emptyDirectories([firefoxCache])]),
            minimumBytes: ProbeSupport.megabyte
        ) {
            items.append(item)
        }

        return items.sorted { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
    }
}

// MARK: - Code editors and IDEs

/// VS Code and its forks share one Electron layout; JetBrains IDEs keep one
/// cache and one settings folder per product version and never remove old
/// ones.
struct EditorProbe: StorageProbe {
    private struct Electron {
        let folder: String
        let name: String
        let bundleIDs: [String]
    }

    private static let electronEditors: [Electron] = [
        Electron(folder: "Code", name: "VS Code", bundleIDs: ["com.microsoft.VSCode"]),
        Electron(folder: "Code - Insiders", name: "VS Code Insiders", bundleIDs: ["com.microsoft.VSCodeInsiders"]),
        Electron(folder: "Cursor", name: "Cursor", bundleIDs: ["com.todesktop.230313mzl4w4u92"]),
        Electron(folder: "Windsurf", name: "Windsurf", bundleIDs: ["com.exafunction.windsurf"]),
        Electron(folder: "VSCodium", name: "VSCodium", bundleIDs: ["com.vscodium"]),
    ]

    private static let electronCaches = [
        "Cache", "CachedData", "CachedExtensionVSIXs", "CachedProfilesData", "Code Cache", "GPUCache",
        "DawnGraphiteCache", "DawnWebGPUCache", "Service Worker/CacheStorage", "Service Worker/ScriptCache", "logs",
    ]

    static let coveredAppSupport: Set<String> = Set(electronEditors.map(\.folder)).union(["JetBrains"])
    static let coveredCaches: Set<String> = ["JetBrains"]

    func probe() async -> [StorageItem] {
        var items: [StorageItem] = []

        for editor in Self.electronEditors {
            let support = URL.home("Library/Application Support/\(editor.folder)")
            guard support.exists else { continue }
            let quit = ReclaimAction.requireQuit(bundleIDs: editor.bundleIDs, appName: editor.name)

            let caches = Self.electronCaches.map { support.appending(path: $0) }.filter(\.exists)
            var total: Int64 = 0
            for folder in caches { total += await DiskSize.allocated(at: folder) }
            if total >= ProbeSupport.megabyte {
                items.append(StorageItem(
                    id: "editor-\(editor.folder)-caches", category: .editors, name: "\(editor.name) caches & logs",
                    detail: "Compiled code, extension downloads, GPU caches and logs. Rebuilt on next launch. Quit \(editor.name) first.",
                    sizeBytes: total, safety: .safe,
                    action: .steps([quit, .emptyDirectories(caches)]), revealURL: caches[0]
                ))
            }

            let workspaces = support.appending(path: "User/workspaceStorage")
            if let item = await ProbeSupport.directoryItem(
                id: "editor-\(editor.folder)-workspaces", category: .editors, name: "\(editor.name) workspace storage",
                detail: "Per-folder state (open tabs, extension data) for every folder ever opened. Never cleaned up by \(editor.name).",
                url: workspaces, safety: .review,
                action: .steps([quit, .emptyDirectories([workspaces])]), minimumBytes: 20 * ProbeSupport.megabyte
            ) {
                items.append(item)
            }
        }

        // JetBrains: caches per product version are always safe; settings of
        // superseded versions are only needed to roll back.
        for cache in URL.home("Library/Caches/JetBrains").children() where cache.isDirectory {
            if let item = await ProbeSupport.directoryItem(
                id: "editor-jetbrains-cache-\(cache.lastPathComponent)", category: .editors,
                name: "\(cache.lastPathComponent) caches",
                detail: "JetBrains indexes and caches. Rebuilt on the next launch.",
                url: cache, safety: .safe, action: .removePaths([cache]), minimumBytes: 10 * ProbeSupport.megabyte
            ) {
                items.append(item)
            }
        }

        let settings = URL.home("Library/Application Support/JetBrains").children().filter(\.isDirectory)
        let byProduct = Dictionary(grouping: settings) { Self.productName($0.lastPathComponent) }
        for (product, versions) in byProduct where versions.count > 1 {
            let ordered = versions.sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
            for old in ordered.dropFirst() {
                if let item = await ProbeSupport.directoryItem(
                    id: "editor-jetbrains-old-\(old.lastPathComponent)", category: .editors,
                    name: "Old \(old.lastPathComponent) settings",
                    detail: "Settings and plugins for a version replaced by \(ordered[0].lastPathComponent). Only needed to roll back \(product).",
                    url: old, safety: .review, action: .removePaths([old]), minimumBytes: 10 * ProbeSupport.megabyte
                ) {
                    items.append(item)
                }
            }
        }

        return items.sorted { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
    }

    /// "IntelliJIdea2024.2" -> "IntelliJIdea".
    static func productName(_ folder: String) -> String {
        String(folder.prefix { !$0.isNumber })
    }
}
