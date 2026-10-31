import Foundation

// MARK: - Virtual machines

/// VM disks are the single largest files most people own and Finder files
/// every one of them under System Data.
struct VirtualMachineProbe: StorageProbe {
    private struct Source {
        let directory: URL
        let suffix: String?
        let product: String
    }

    private static let sources: [Source] = [
        Source(directory: .home("Parallels"), suffix: "pvm", product: "Parallels"),
        Source(directory: .home("Documents/Parallels"), suffix: "pvm", product: "Parallels"),
        Source(directory: .home("Library/Containers/com.utmapp.UTM/Data/Documents"), suffix: "utm", product: "UTM"),
        Source(directory: .home("Virtual Machines.localized"), suffix: "vmwarevm", product: "VMware Fusion"),
        Source(directory: .home("Documents/Virtual Machines.localized"), suffix: "vmwarevm", product: "VMware Fusion"),
        Source(directory: .home("VirtualBox VMs"), suffix: nil, product: "VirtualBox"),
        Source(directory: .home(".tart/vms"), suffix: nil, product: "Tart"),
    ]

    func probe() async -> [StorageItem] {
        var items: [StorageItem] = []
        for source in Self.sources {
            for machine in source.directory.children()
            where machine.isDirectory && (source.suffix == nil || machine.pathExtension == source.suffix) {
                if let item = await ProbeSupport.directoryItem(
                    id: "vm-\(machine.path)", category: .vms,
                    name: "\(source.product): \(machine.deletingPathExtension().lastPathComponent)",
                    detail: "A whole virtual machine, including everything installed inside it.",
                    url: machine, safety: .review, action: .removePaths([machine]),
                    minimumBytes: 50 * ProbeSupport.megabyte
                ) {
                    items.append(item)
                }
            }
        }
        return items.sorted { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
    }
}

// MARK: - Media, chat and creative app caches

/// Apps that keep multi-gigabyte caches outside ~/Library/Caches, where the
/// generic scan would only see the parent folder.
struct AppCacheProbe: StorageProbe {
    private struct Entry {
        let id: String
        let name: String
        let paths: [String]
        let detail: String
        let safety: Safety
        let category: StorageCategory

        init(id: String, name: String, path: String..., detail: String, safety: Safety, category: StorageCategory = .apps) {
            self.id = id
            self.name = name
            self.paths = path
            self.detail = detail
            self.safety = safety
            self.category = category
        }
    }

    private static let entries: [Entry] = [
        Entry(id: "slack", name: "Slack cache",
              path: "Library/Application Support/Slack/Cache", "Library/Application Support/Slack/Code Cache",
              "Library/Application Support/Slack/GPUCache",
              detail: "Message and file previews. Rebuilt as you use Slack.", safety: .safe, category: .chat),
        Entry(id: "slack-sw", name: "Slack service worker cache", path: "Library/Application Support/Slack/Service Worker/CacheStorage",
              detail: "Web app assets. Re-downloaded on next launch.", safety: .safe, category: .chat),
        Entry(id: "discord", name: "Discord cache",
              path: "Library/Application Support/discord/Cache", "Library/Application Support/discord/Code Cache",
              "Library/Application Support/discord/GPUCache",
              detail: "Media previews and compiled scripts. Rebuilt as you use Discord.", safety: .safe, category: .chat),
        Entry(id: "teams", name: "Microsoft Teams cache", path: "Library/Containers/com.microsoft.teams2/Data/Library/Caches",
              detail: "Rebuilt as you use Teams.", safety: .safe, category: .chat),
        Entry(id: "zoom", name: "Zoom data", path: "Library/Application Support/zoom.us",
              detail: "Update packages and logs. Zoom re-downloads what it needs.", safety: .review, category: .chat),
        Entry(id: "whatsapp-media", name: "WhatsApp media",
              path: "Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message/Media",
              detail: "Photos, videos and documents received in chats. Removed from this Mac only; your phone keeps its copy.",
              safety: .review, category: .chat),
        Entry(id: "telegram-media", name: "Telegram media cache",
              path: "Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram/stable",
              detail: "Downloaded media for every account. Telegram fetches it again from the cloud when opened.",
              safety: .review, category: .chat),
        Entry(id: "messenger", name: "Messenger cache", path: "Library/Containers/com.facebook.archon/Data/Library/Caches",
              detail: "Rebuilt as you use Messenger.", safety: .safe, category: .chat),
        Entry(id: "webex", name: "Webex cache", path: "Library/Caches/com.cisco.webexmeetingsapp",
              detail: "Meeting client downloads.", safety: .safe, category: .chat),
        Entry(id: "spotify", name: "Spotify cache", path: "Library/Application Support/Spotify/PersistentCache",
              detail: "Streamed audio cache. Downloaded playlists are kept elsewhere.", safety: .safe),
        Entry(id: "adobe-media", name: "Adobe media cache", path: "Library/Application Support/Adobe/Common/Media Cache Files",
              detail: "Premiere and After Effects render caches. Rebuilt when a project opens.", safety: .safe),
        Entry(id: "adobe-caches", name: "Adobe caches", path: "Library/Caches/Adobe",
              detail: "Creative Cloud app caches.", safety: .safe),
        Entry(id: "adobe-cc", name: "Creative Cloud installers", path: "Library/Application Support/Adobe/Adobe Desktop Common",
              detail: "Downloaded installers and update payloads.", safety: .review),
        Entry(id: "steam", name: "Steam games", path: "Library/Application Support/Steam/steamapps",
              detail: "Installed games. Uninstall from Steam to keep your saves in sync.", safety: .review),
        Entry(id: "epic", name: "Epic Games launcher data", path: "Library/Application Support/Epic",
              detail: "Launcher caches and downloads.", safety: .review),
        Entry(id: "xcode-device-logs", name: "iOS device logs", path: "Library/Developer/Xcode/iOS Device Logs",
              detail: "Crash logs copied from connected devices.", safety: .safe),
        Entry(id: "coresim-logs", name: "CoreSimulator logs", path: "Library/Logs/CoreSimulator",
              detail: "Per-simulator system logs.", safety: .safe),
        Entry(id: "photos-cache", name: "Photos caches", path: "Library/Containers/com.apple.photolibraryd/Data/Library/Caches",
              detail: "Thumbnails and derivatives. Your library is untouched.", safety: .safe),
        Entry(id: "quicklook", name: "Quick Look thumbnails", path: "Library/Caches/com.apple.QuickLook.thumbnailcache",
              detail: "Preview thumbnails. Rebuilt on demand.", safety: .safe),
    ]

    func probe() async -> [StorageItem] {
        var items: [StorageItem] = []
        for entry in Self.entries {
            let urls = entry.paths.map(URL.home).filter(\.exists)
            guard !urls.isEmpty else { continue }
            var total: Int64 = 0
            for url in urls { total += await DiskSize.allocated(at: url) }
            guard total >= 20 * ProbeSupport.megabyte else { continue }
            items.append(StorageItem(
                id: "cache-\(entry.id)", category: entry.category, name: entry.name, detail: entry.detail,
                sizeBytes: total, safety: entry.safety, action: .emptyDirectories(urls), revealURL: urls[0],
                alsoClaims: Array(urls.dropFirst())
            ))
        }

        // Final Cut Pro render files live inside each library bundle.
        for root in [URL.home("Movies"), URL.home("Documents")] {
            for library in root.children() where library.pathExtension == "fcpbundle" {
                let renders = library.children().filter(\.isDirectory)
                    .map { $0.appending(path: "Render Files") }
                    .filter(\.exists)
                guard !renders.isEmpty else { continue }
                var total: Int64 = 0
                for folder in renders { total += await DiskSize.allocated(at: folder) }
                guard total >= 20 * ProbeSupport.megabyte else { continue }
                items.append(StorageItem(
                    id: "fcp-renders-\(library.path)", category: .apps,
                    name: "Final Cut render files: \(library.deletingPathExtension().lastPathComponent)",
                    detail: "Regenerated when the project is opened. Prefer File > Delete Generated Library Files in Final Cut.",
                    sizeBytes: total, safety: .safe, action: .emptyDirectories(renders), revealURL: library
                ))
            }
        }

        return items.sorted { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
    }
}
