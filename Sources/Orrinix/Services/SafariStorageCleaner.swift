import AppKit
import Foundation
import Observation

/// The only locations Orrinix is ever permitted to modify for Safari.
/// Bookmarks, profiles, passwords, history, and the Safari app itself are
/// intentionally outside this allow-list.
struct SafariStoragePaths: Sendable {
    let container: URL
    let websiteData: URL
    let defaultOrigins: URL
    let containerCaches: URL
    let globalCaches: URL
    let safariFolder: URL

    static let live = SafariStoragePaths(
        container: .home("Library/Containers/com.apple.Safari"),
        websiteData: .home("Library/Containers/com.apple.Safari/Data/Library/WebKit/WebsiteData"),
        defaultOrigins: .home("Library/Containers/com.apple.Safari/Data/Library/WebKit/WebsiteData/Default"),
        containerCaches: .home("Library/Containers/com.apple.Safari/Data/Library/Caches"),
        globalCaches: .home("Library/Caches/com.apple.Safari"),
        safariFolder: .home("Library/Safari")
    )
}

enum SafariCleanupMode: Sendable, Equatable, Identifiable {
    case quick
    case websiteData
    case targeted(URL)

    var id: String {
        switch self {
        case .quick: "quick"
        case .websiteData: "website-data"
        case .targeted(let origin): "targeted-\(origin.path)"
        }
    }

    var title: String {
        switch self {
        case .quick: L("Clear Safari Cache")
        case .websiteData: L("Clean Safari Website Data")
        case .targeted: L("Clean This Website Only")
        }
    }
}

struct SafariFile: Identifiable, Equatable, Sendable {
    let url: URL
    let bytes: Int64

    var id: String { url.path }
    var displayName: String { url.lastPathComponent }
}

struct SafariOrigin: Identifiable, Equatable, Sendable {
    let url: URL
    let bytes: Int64
    let largestWAL: SafariFile?

    var id: String { url.path }
}

struct SafariStorageReport: Equatable, Sendable {
    let totalBytes: Int64
    let websiteDataBytes: Int64
    let cacheBytes: Int64
    let otherBytes: Int64
    let origins: [SafariOrigin]
    let largestFiles: [SafariFile]
    let largestWAL: SafariFile?
    let permissionRestricted: Bool
    let scannedAt: Date

    var recommendedMode: SafariCleanupMode {
        if let origin = origins.max(by: { $0.bytes < $1.bytes }),
           websiteDataBytes > 0,
           origin.bytes * 100 >= websiteDataBytes * 70,
           origin.largestWAL?.bytes ?? 0 >= 500 * ProbeSupport.megabyte {
            return .targeted(origin.url)
        }
        if websiteDataBytes >= 500 * ProbeSupport.megabyte { return .websiteData }
        return .quick
    }

    var hasRunawayWAL: Bool {
        (largestWAL?.bytes ?? 0) >= 500 * ProbeSupport.megabyte
    }

    var walSeverity: String? {
        guard let bytes = largestWAL?.bytes, bytes >= 500 * ProbeSupport.megabyte else { return nil }
        if bytes >= 20 * 1024 * ProbeSupport.megabyte { return L("Runaway") }
        if bytes >= 5 * 1024 * ProbeSupport.megabyte { return L("Critical") }
        return L("Warning")
    }
}

struct SafariCleanupResult: Equatable, Sendable {
    let mode: SafariCleanupMode
    let before: SafariStorageReport
    let after: SafariStorageReport
    let physicalFreeBefore: Int64
    let physicalFreeAfter: Int64

    var recoveredBytes: Int64 { max(before.totalBytes - after.totalBytes, 0) }
    var recoveredPhysicalBytes: Int64 { max(physicalFreeAfter - physicalFreeBefore, 0) }
}

struct SafariCleanupHistoryRecord: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let date: Date
    let mode: String
    let beforeBytes: Int64
    let afterBytes: Int64
    let recoveredBytes: Int64
}

enum SafariCleanerError: LocalizedError {
    case safariStillRunning
    case unsafePath
    case partialCleanup(Int)

    var errorDescription: String? {
        switch self {
        case .safariStillRunning: L("Safari must be closed before cleaning.")
        case .unsafePath: L("Orrinix refused an unsafe Safari cleanup path.")
        case .partialCleanup(let count): L("Safari cleanup could not remove %lld item(s).", count)
        }
    }
}

enum SafariStorageCleaner {
    static func scan(paths: SafariStoragePaths = .live) async -> SafariStorageReport {
        await Task.detached(priority: .utility) { scanSync(paths: paths) }.value
    }

    static func clean(
        _ mode: SafariCleanupMode,
        paths: SafariStoragePaths = .live,
        requiresSafariToBeClosed: Bool = true
    ) async throws -> SafariCleanupResult {
        if requiresSafariToBeClosed {
            try await quitSafariIfNeeded()
        }
        let before = await scan(paths: paths)
        // A large WebsiteData scan can take a while. If the user reopened
        // Safari during it, never race WebKit's databases: require another
        // explicit attempt instead.
        if requiresSafariToBeClosed, isSafariRunning {
            throw SafariCleanerError.safariStillRunning
        }
        let physicalFreeBefore = DiskSize.metrics().physicalFreeBytes
        try await Task.detached(priority: .utility) {
            try remove(mode, paths: paths)
        }.value
        let after = await scan(paths: paths)
        return SafariCleanupResult(
            mode: mode, before: before, after: after,
            physicalFreeBefore: physicalFreeBefore,
            physicalFreeAfter: DiskSize.metrics().physicalFreeBytes
        )
    }

    private static func scanSync(paths: SafariStoragePaths) -> SafariStorageReport {
        let container = measure(paths.container)
        let website = measure(paths.websiteData, collectingFiles: true)
        let containerCaches = measure(paths.containerCaches)
        let globalCaches = measure(paths.globalCaches)
        let safariFolder = measure(paths.safariFolder)

        let origins = paths.defaultOrigins.children(includeHidden: true)
            .filter(\.isDirectory)
            .map { origin in
                let usage = measure(origin)
                let wal = website.files
                    .filter { $0.url.path.hasPrefix(origin.standardizedFileURL.path + "/") && isWAL($0.url) }
                    .max(by: { $0.bytes < $1.bytes })
                return SafariOrigin(url: origin, bytes: usage.bytes, largestWAL: wal)
            }
            .filter { $0.bytes > 0 }
            .sorted { $0.bytes > $1.bytes }

        let cacheBytes = containerCaches.bytes + globalCaches.bytes
        let otherBytes = max(container.bytes - website.bytes - containerCaches.bytes, 0) + safariFolder.bytes
        return SafariStorageReport(
            totalBytes: container.bytes + globalCaches.bytes + safariFolder.bytes,
            websiteDataBytes: website.bytes,
            cacheBytes: cacheBytes,
            otherBytes: otherBytes,
            origins: origins,
            largestFiles: website.files.sorted { $0.bytes > $1.bytes }.prefix(8).map { $0 },
            largestWAL: website.files.filter { isWAL($0.url) }.max(by: { $0.bytes < $1.bytes }),
            permissionRestricted: container.denied || website.denied || containerCaches.denied || globalCaches.denied || safariFolder.denied,
            scannedAt: .now
        )
    }

    private static func quitSafariIfNeeded() async throws {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari")
        guard !running.isEmpty else { return }
        running.forEach { $0.terminate() }
        for _ in 0..<5 {
            try? await Task.sleep(for: .seconds(1))
            if !isSafariRunning { return }
        }
        throw SafariCleanerError.safariStillRunning
    }

    static var isSafariRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").isEmpty
    }

    private static func remove(_ mode: SafariCleanupMode, paths: SafariStoragePaths) throws {
        switch mode {
        case .quick:
            try removeContents(of: paths.containerCaches, allowedRoot: paths.containerCaches)
            try removeContents(of: paths.globalCaches, allowedRoot: paths.globalCaches)
        case .websiteData:
            try removeContents(of: paths.websiteData, allowedRoot: paths.websiteData)
        case .targeted(let origin):
            try removeTarget(origin, inside: paths.defaultOrigins)
        }
    }

    private static func removeContents(of root: URL, allowedRoot: URL) throws {
        guard root.exists else { return }
        let children = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []
        )
        var failures = 0
        for child in children {
            do {
                try validate(child, inside: allowedRoot)
                try FileManager.default.removeItem(at: child)
            } catch {
                failures += 1
            }
        }
        if failures > 0 { throw SafariCleanerError.partialCleanup(failures) }
    }

    private static func removeTarget(_ target: URL, inside root: URL) throws {
        guard target.exists else { return }
        try validate(target, inside: root)
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let canonicalTarget = target.resolvingSymlinksInPath().standardizedFileURL.path
        guard URL(fileURLWithPath: canonicalTarget).deletingLastPathComponent().path == canonicalRoot else {
            throw SafariCleanerError.unsafePath
        }
        try FileManager.default.removeItem(at: target)
    }

    private static func validate(_ target: URL, inside root: URL) throws {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let targetPath = target.resolvingSymlinksInPath().standardizedFileURL.path
        guard targetPath.hasPrefix(rootPath + "/") else { throw SafariCleanerError.unsafePath }
    }

    private static func isWAL(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name == "localstorage.sqlite3-wal" || (name.contains(".sqlite") && name.hasSuffix("-wal"))
    }

    private static func measure(_ root: URL, collectingFiles: Bool = false) -> (bytes: Int64, denied: Bool, files: [SafariFile]) {
        guard root.exists else { return (0, false, []) }
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey]
        do {
            _ = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys), options: [])
        } catch {
            return (0, true, [])
        }
        guard let enumerator = manager.enumerator(
            at: root, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true }
        ) else { return (0, true, []) }

        var bytes: Int64 = 0
        var files: [SafariFile] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            if values.isSymbolicLink == true {
                if values.isRegularFile != true { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true else { continue }
            let size = Int64(values.totalFileAllocatedSize ?? 0)
            bytes += size
            if collectingFiles, (isWAL(url) || files.count < 40) {
                files.append(SafariFile(url: url, bytes: size))
            }
        }
        return (bytes, false, files)
    }
}

@MainActor
@Observable
final class SafariStorageModel {
    private(set) var report: SafariStorageReport?
    private(set) var isScanning = false
    private(set) var isCleaning = false
    private(set) var lastResult: SafariCleanupResult?
    private(set) var history: [SafariCleanupHistoryRecord] = []
    var errorMessage: String?

    private static let historyKey = "safariCleanupHistory"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.historyKey),
           let saved = try? JSONDecoder().decode([SafariCleanupHistoryRecord].self, from: data) {
            history = saved
        }
    }

    func scan() async {
        guard !isScanning && !isCleaning else { return }
        isScanning = true
        errorMessage = nil
        report = await SafariStorageCleaner.scan()
        isScanning = false
    }

    func clean(_ mode: SafariCleanupMode) async {
        guard !isCleaning else { return }
        isCleaning = true
        errorMessage = nil
        defer { isCleaning = false }
        do {
            let result = try await SafariStorageCleaner.clean(mode)
            lastResult = result
            report = result.after
            let record = SafariCleanupHistoryRecord(
                id: UUID(), date: .now, mode: mode.title,
                beforeBytes: result.before.totalBytes, afterBytes: result.after.totalBytes,
                recoveredBytes: result.recoveredBytes
            )
            history.insert(record, at: 0)
            history = Array(history.prefix(20))
            if let data = try? JSONEncoder().encode(history) {
                UserDefaults.standard.set(data, forKey: Self.historyKey)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
