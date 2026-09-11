import Darwin
import Foundation

/// Fast, volume-level accounting. Directory probes are explanatory estimates
/// and must never be used for these values.
struct StorageMetrics: Equatable, Sendable {
    let totalBytes: Int64
    let physicalFreeBytes: Int64
    let usedBytes: Int64
    let importantUsageAvailableBytes: Int64?
    let opportunisticAvailableBytes: Int64?
    let estimatedReclaimableBytes: Int64?
    let mountPoint: URL
    let filesystemType: String?
    let volumeName: String?
    let updatedAt: Date

    init(
        totalBytes: Int64,
        physicalFreeBytes: Int64,
        importantUsageAvailableBytes: Int64? = nil,
        opportunisticAvailableBytes: Int64? = nil,
        mountPoint: URL = URL(fileURLWithPath: "/System/Volumes/Data"),
        filesystemType: String? = nil,
        volumeName: String? = nil,
        updatedAt: Date = .now
    ) {
        let total = max(totalBytes, 0)
        let free = min(max(physicalFreeBytes, 0), total)
        let important = importantUsageAvailableBytes.map { min(max($0, free), total) }
        let opportunistic = opportunisticAvailableBytes.map { min(max($0, free), total) }
        self.totalBytes = total
        self.physicalFreeBytes = free
        usedBytes = total - free
        self.importantUsageAvailableBytes = important
        self.opportunisticAvailableBytes = opportunistic
        estimatedReclaimableBytes = (important ?? opportunistic).map { max($0 - free, 0) }
        self.mountPoint = mountPoint
        self.filesystemType = filesystemType
        self.volumeName = volumeName
        self.updatedAt = updatedAt
    }

    /// The maximum available capacity macOS advertises after reclaiming
    /// purgeable data. It is intentionally never shown as primary Free.
    var potentialAvailableBytes: Int64? {
        importantUsageAvailableBytes ?? opportunisticAvailableBytes
    }
}

enum DiskSize {
    /// Allocated bytes under `url`, following the same rules Finder uses for
    /// System Data: on-disk blocks, no symlink traversal.
    static func allocated(at url: URL, olderThan cutoff: Date? = nil) async -> Int64 {
        await Task.detached(priority: .utility) {
            allocatedSync(at: url, olderThan: cutoff)
        }.value
    }

    static func allocatedSync(at url: URL, olderThan cutoff: Date? = nil) -> Int64 {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }

        let keys: Set<URLResourceKey> = [
            .totalFileAllocatedSizeKey, .isRegularFileKey, .contentModificationDateKey,
        ]

        if !isDirectory.boolValue {
            return size(of: url, keys: keys, cutoff: cutoff)
        }

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        for case let child as URL in enumerator {
            total += size(of: child, keys: keys, cutoff: cutoff)
        }
        return total
    }

    /// Allocated size of every directory under `root` up to `maxDepth` levels,
    /// keyed by path, from a single enumeration. Used by the catch-all scan so
    /// it does not re-walk the same tree once per level.
    static func directorySizes(under root: URL, maxDepth: Int) -> [String: Int64] {
        let rootPath = root.standardizedFileURL.path
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: rootPath),
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else { return [:] }

        var sizes: [String: Int64] = [:]
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let size = values.totalFileAllocatedSize, size > 0 else { continue }

            let relative = file.path.dropFirst(rootPath.count + 1)
            let components = relative.split(separator: "/", omittingEmptySubsequences: true).dropLast()
            var directory = rootPath
            sizes[directory, default: 0] += Int64(size)
            for component in components.prefix(maxDepth) {
                directory += "/" + component
                sizes[directory, default: 0] += Int64(size)
            }
        }
        return sizes
    }

    /// Reads the startup Data volume's physical filesystem capacity.
    /// `statfs.f_bavail` is the current free block count; the URL capacity
    /// values are retained only as separately-labelled reclaimable hints.
    static func metrics(at mountPoint: URL = startupDataVolume) -> StorageMetrics {
        let values = try? mountPoint.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityForOpportunisticUsageKey,
            .volumeNameKey,
        ])
        let important = values?.volumeAvailableCapacityForImportantUsage.flatMap { $0 > 0 ? Int64($0) : nil }
        let opportunistic = values?.volumeAvailableCapacityForOpportunisticUsage.flatMap { $0 > 0 ? Int64($0) : nil }

        if var stats = statfsValues(for: mountPoint.path),
           let total = byteCount(blocks: stats.f_blocks, blockSize: stats.f_bsize),
           let free = byteCount(blocks: stats.f_bavail, blockSize: stats.f_bsize) {
            return StorageMetrics(
                totalBytes: total,
                physicalFreeBytes: free,
                importantUsageAvailableBytes: important,
                opportunisticAvailableBytes: opportunistic,
                mountPoint: mountPoint,
                filesystemType: filesystemName(&stats),
                volumeName: values?.volumeName
            )
        }

        if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: mountPoint.path),
           let total = (attributes[.systemSize] as? NSNumber)?.int64Value,
           let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value {
            return StorageMetrics(
                totalBytes: total,
                physicalFreeBytes: free,
                importantUsageAvailableBytes: important,
                opportunisticAvailableBytes: opportunistic,
                mountPoint: mountPoint,
                volumeName: values?.volumeName
            )
        }

        let fallback = try? mountPoint.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        return StorageMetrics(
            totalBytes: Int64(fallback?.volumeTotalCapacity ?? 0),
            physicalFreeBytes: Int64(fallback?.volumeAvailableCapacity ?? 0),
            importantUsageAvailableBytes: important,
            opportunisticAvailableBytes: opportunistic,
            mountPoint: mountPoint,
            volumeName: values?.volumeName
        )
    }

    static var startupDataVolume: URL {
        let data = URL(fileURLWithPath: "/System/Volumes/Data")
        return data.exists ? data : URL(fileURLWithPath: "/")
    }

    private static func statfsValues(for path: String) -> statfs? {
        var stats = statfs()
        guard path.withCString({ statfs($0, &stats) }) == 0 else { return nil }
        return stats
    }

    private static func byteCount(blocks: UInt64, blockSize: UInt32) -> Int64? {
        let blockSize = UInt64(blockSize)
        guard blockSize > 0, blocks <= UInt64(Int64.max) / blockSize else { return nil }
        return Int64(blocks * blockSize)
    }

    private static func filesystemName(_ stats: inout statfs) -> String? {
        withUnsafeBytes(of: &stats.f_fstypename) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
        }
    }

    /// The `limit` biggest direct children of a directory, measured on disk.
    static func largestChildren(of url: URL, limit: Int = 5) async -> [(url: URL, bytes: Int64)] {
        await Task.detached(priority: .utility) {
            url.children(includeHidden: true)
                .map { ($0, allocatedSync(at: $0)) }
                .filter { $0.1 > 0 }
                .sorted { $0.1 > $1.1 }
                .prefix(limit)
                .map { (url: $0.0, bytes: $0.1) }
        }.value
    }

    private static func size(of url: URL, keys: Set<URLResourceKey>, cutoff: Date?) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isRegularFile == true else { return 0 }
        if let cutoff, let modified = values.contentModificationDate, modified > cutoff {
            return 0
        }
        return Int64(values.totalFileAllocatedSize ?? 0)
    }
}

extension URL {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static func home(_ path: String) -> URL {
        home.appending(path: path)
    }

    var exists: Bool { FileManager.default.fileExists(atPath: path) }

    /// Non-hidden, direct children sorted by name.
    func children(includeHidden: Bool = false) -> [URL] {
        let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: self, includingPropertiesForKeys: [.isDirectoryKey], options: options
        )) ?? []
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    var isDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    var abbreviatedPath: String {
        let home = URL.home.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
