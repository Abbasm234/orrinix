import Foundation
import Observation

/// One file the large-file finder turned up.
struct LargeFile: Identifiable, Equatable, Sendable {
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case all, installers, archives, videos, diskImages, other

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: L("All kinds")
            case .installers: L("Installers")
            case .archives: L("Archives")
            case .videos: L("Videos")
            case .diskImages: L("Disk images")
            case .other: L("Other")
            }
        }

        var symbol: String {
            switch self {
            case .all: "doc"
            case .installers: "shippingbox"
            case .archives: "doc.zipper"
            case .videos: "film"
            case .diskImages: "opticaldiscdrive"
            case .other: "doc"
            }
        }

        static func of(_ url: URL) -> Kind {
            switch url.pathExtension.lowercased() {
            case "pkg", "mpkg", "xip": .installers
            case "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar": .archives
            case "mov", "mp4", "m4v", "mkv", "avi", "webm", "mts": .videos
            case "dmg", "iso", "img", "ipsw", "sparseimage", "sparsebundle", "vmdk", "qcow2": .diskImages
            default: .other
            }
        }
    }

    let url: URL
    let bytes: Int64
    /// When the file was last opened, falling back to its modification date.
    let lastUsed: Date?
    let kind: Kind

    var id: String { url.path }
}

enum LargeFileFinder {
    static let defaultRoots: [URL] = ["Downloads", "Desktop", "Documents", "Movies", "Music"].map(URL.home)

    /// Every regular file of at least `minimumBytes` under `roots`. Hidden
    /// files and the insides of packages (apps, Photos libraries) are skipped.
    static func scan(roots: [URL], minimumBytes: Int64) async -> [LargeFile] {
        await Task.detached(priority: .utility) { scanSync(roots: roots, minimumBytes: minimumBytes) }.value
    }

    private static func scanSync(roots: [URL], minimumBytes: Int64) -> [LargeFile] {
            var found: [LargeFile] = []
            let keys: [URLResourceKey] = [
                .isRegularFileKey, .totalFileAllocatedSizeKey, .contentAccessDateKey, .contentModificationDateKey,
            ]
            for root in roots where root.exists {
                guard let enumerator = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true }
                ) else { continue }
                for case let url as URL in enumerator {
                    guard let values = try? url.resourceValues(forKeys: Set(keys)),
                          values.isRegularFile == true else { continue }
                    let bytes = Int64(values.totalFileAllocatedSize ?? 0)
                    guard bytes >= minimumBytes else { continue }
                    found.append(LargeFile(
                        url: url, bytes: bytes,
                        lastUsed: values.contentAccessDate ?? values.contentModificationDate,
                        kind: .of(url)
                    ))
                }
            }
            return found.sorted { $0.bytes > $1.bytes }
    }
}

@MainActor
@Observable
final class LargeFilesModel {
    enum Age: Int, CaseIterable, Identifiable {
        case any = 0, month = 30, quarter = 90, year = 365

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .any: L("Any age")
            case .month: L("Unused 30+ days")
            case .quarter: L("Unused 90+ days")
            case .year: L("Unused 1+ year")
            }
        }
    }

    /// Decimal, so the labels read "100 MB" rather than "104.9 MB".
    static let sizeSteps: [Int64] = [50, 100, 250, 500, 1_000].map { $0 * 1_000_000 }

    private(set) var files: [LargeFile] = []
    private(set) var isScanning = false
    private(set) var hasScanned = false
    private(set) var isDeleting = false
    var roots: [URL] = LargeFileFinder.defaultRoots
    var minimumBytes: Int64 = 100_000_000
    var age: Age = .any
    var kind: LargeFile.Kind = .all
    var selectedIDs: Set<String> = []
    var errorMessage: String?

    /// Everything over the smallest threshold is kept, so changing filters
    /// never needs a rescan.
    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        errorMessage = nil
        files = await LargeFileFinder.scan(roots: roots, minimumBytes: Self.sizeSteps[0])
        selectedIDs = selectedIDs.intersection(files.map(\.id))
        isScanning = false
        hasScanned = true
    }

    var visibleFiles: [LargeFile] {
        let cutoff = Date().addingTimeInterval(-Double(age.rawValue) * 86_400)
        return files.filter { file in
            file.bytes >= minimumBytes
                && (kind == .all || file.kind == kind)
                && (age == .any || (file.lastUsed.map { $0 < cutoff } ?? true))
        }
    }

    var selectedFiles: [LargeFile] {
        visibleFiles.filter { selectedIDs.contains($0.id) }
    }

    func toggle(_ file: LargeFile) {
        if selectedIDs.contains(file.id) { selectedIDs.remove(file.id) } else { selectedIDs.insert(file.id) }
    }

    func addRoot(_ url: URL) {
        guard !roots.contains(url) else { return }
        roots.append(url)
    }

    func removeRoot(_ url: URL) {
        roots.removeAll { $0 == url }
        files.removeAll { $0.url.path.hasPrefix(url.path + "/") }
    }

    /// Moves the selection to the Trash. Returns the bytes the volume
    /// actually released (zero until the Trash is emptied).
    func trashSelected() async -> Int64 {
        let chosen = selectedFiles
        guard !chosen.isEmpty else { return 0 }
        isDeleting = true
        defer { isDeleting = false }
        errorMessage = nil
        let before = DiskSize.metrics().physicalFreeBytes
        do {
            try await Reclaimer.perform(.removePaths(chosen.map(\.url)), preferTrash: true)
        } catch {
            errorMessage = error.localizedDescription
        }
        let gone = Set(chosen.filter { !$0.url.exists }.map(\.id))
        files.removeAll { gone.contains($0.id) }
        selectedIDs.subtract(gone)
        return max(DiskSize.metrics().physicalFreeBytes - before, 0)
    }
}
