import Foundation
import Testing
@testable import Orrinix

/// Every probe runs against the real machine, so only invariants are checked:
/// probes must not throw or hang, and what they return must be well-formed.
@Suite struct ProbeTests {
    private let probes: [(String, any StorageProbe)] = ProbeRegistry.all.map { (String(describing: type(of: $0)), $0) }

    @Test func storageMetricsKeepReclaimableCapacityOutOfFree() {
        let metrics = StorageMetrics(
            totalBytes: 494_380_000_000,
            physicalFreeBytes: 152_130_000_000,
            importantUsageAvailableBytes: 183_460_000_000
        )

        #expect(metrics.physicalFreeBytes == 152_130_000_000)
        #expect(metrics.usedBytes == 342_250_000_000)
        #expect(metrics.estimatedReclaimableBytes == 31_330_000_000)
        #expect(metrics.potentialAvailableBytes == 183_460_000_000)
        #expect(metrics.physicalFreeBytes != metrics.potentialAvailableBytes)
    }

    @Test func liveStorageMetricsAreMathematicallyConsistent() {
        let metrics = DiskSize.metrics()
        #expect(metrics.totalBytes > 0)
        #expect(metrics.physicalFreeBytes >= 0)
        #expect(metrics.physicalFreeBytes <= metrics.totalBytes)
        #expect(metrics.usedBytes == metrics.totalBytes - metrics.physicalFreeBytes)
        #expect(metrics.usedBytes >= 0)
        if let potential = metrics.potentialAvailableBytes {
            #expect(potential >= metrics.physicalFreeBytes)
            #expect(potential <= metrics.totalBytes)
        }
    }

    @Test func itemsAreWellFormed() async {
        var seen: Set<String> = []
        var all: [StorageItem] = []
        for (label, probe) in probes {
            let items = await probe.probe()
            all += items
            check(items, label: label, seen: &seen)
        }
        let catchAll = await LargeFolderProbe(claimed: all.flatMap(\.claimedURLs)).probe()
        check(catchAll, label: "other", seen: &seen)
        all += catchAll

        // Inventory of this machine, for whoever reads the test log.
        let total = all.reduce(0) { $0 + ($1.sizeBytes ?? 0) }
        print("Inventory: \(all.count) items, \(total.byteString)")
        for item in all.sorted(by: { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }) {
            print("  \(item.sizeBytes?.byteString ?? "?")\t\(item.category.rawValue)\t\(item.name)")
        }
    }

    private func check(_ items: [StorageItem], label: String, seen: inout Set<String>) {
        for item in items {
                #expect(!item.id.isEmpty, "\(label): empty id")
                #expect(!item.name.isEmpty, "\(label): empty name")
                #expect(!item.detail.isEmpty, "\(label): empty detail for \(item.name)")
                #expect(seen.insert(item.id).inserted, "\(label): duplicate id \(item.id)")
                if let size = item.sizeBytes {
                    #expect(size > 0, "\(label): zero-size item \(item.name) should have been dropped")
                }
                #expect(item.action.isManual == (item.safety == .manual),
                        "\(label): \(item.name) mixes manual safety with a runnable action")
                if let url = item.revealURL {
                    #expect(url.isFileURL, "\(label): reveal URL is not a file URL")
                }
        }
    }

    @Test func directorySizeMatchesWrittenBytes() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "sysdata-size-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "nested"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data(count: 10_000).write(to: root.appending(path: "a.bin"))
        try Data(count: 20_000).write(to: root.appending(path: "nested/b.bin"))

        let measured = DiskSize.allocatedSync(at: root)
        // Allocated size rounds up to filesystem blocks, so allow one block per file.
        #expect(measured >= 30_000 && measured <= 30_000 + 2 * 4096)
    }

    @Test func removePathsActuallyDeletesTemporaryData() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "orrinix-delete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "payload.bin")
        try Data(count: 32_768).write(to: file)
        defer { try? FileManager.default.removeItem(at: root) }

        try await Reclaimer.perform(.removePaths([root]))

        #expect(!root.exists, "The cleanup action must remove the selected path.")
    }

    @Test func dockerContainerIsOwnedByDockerProbe() {
        #expect(AppDataProbe.coveredContainers.contains("com.docker.docker"))
    }

    @Test func safariTargetedCleanupOnlyRemovesTheSelectedWebsiteOrigin() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "orrinix-safari-\(UUID().uuidString)")
        let container = root.appending(path: "container")
        let websiteData = container.appending(path: "Data/Library/WebKit/WebsiteData")
        let defaultOrigins = websiteData.appending(path: "Default")
        let origin = defaultOrigins.appending(path: "example-origin")
        let wal = origin.appending(path: "LocalStorage/localstorage.sqlite3-wal")
        let bookmarks = root.appending(path: "Safari/Bookmarks.plist")
        try FileManager.default.createDirectory(at: wal.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bookmarks.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 32_768).write(to: wal)
        try Data("bookmarks".utf8).write(to: bookmarks)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = SafariStoragePaths(
            container: container,
            websiteData: websiteData,
            defaultOrigins: defaultOrigins,
            containerCaches: container.appending(path: "Data/Library/Caches"),
            globalCaches: root.appending(path: "Caches/com.apple.Safari"),
            safariFolder: bookmarks.deletingLastPathComponent()
        )
        let report = await SafariStorageCleaner.scan(paths: paths)
        #expect(report.websiteDataBytes > 0)
        #expect(report.origins.count == 1)
        #expect(report.largestWAL?.displayName == "localstorage.sqlite3-wal")

        let result = try await SafariStorageCleaner.clean(
            .targeted(origin), paths: paths, requiresSafariToBeClosed: false
        )

        #expect(!origin.exists)
        #expect(bookmarks.exists, "Safari bookmarks must be outside the cleanup allow-list.")
        #expect(result.recoveredBytes > 0)
    }

    @Test func shellQuotingSurvivesSingleQuotes() {
        #expect(Shell.shellQuote("/tmp/it's here") == "'/tmp/it'\\''s here'")
    }

    @Test func whichFindsSystemTools() {
        #expect(Shell.which("tmutil") == "/usr/bin/tmutil")
        #expect(Shell.which("definitely-not-a-tool") == nil)
    }

    @Test func turkishCatalogCoversEveryInterfaceString() throws {
        // The catalog ships with the module and must have a Turkish string for
        // each English key, otherwise the UI silently mixes languages.
        let url = try #require(Bundle.module.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "tr"))
        let turkish = try #require(NSDictionary(contentsOf: url) as? [String: String])
        #expect(turkish["Rescan"] == "Yeniden tara")
        #expect(turkish["Safe"] == "Güvenli")
        for category in StorageCategory.allCases {
            #expect(turkish[englishTitle(category)] != nil, "missing Turkish title for \(category.rawValue)")
        }
    }

    private func englishTitle(_ category: StorageCategory) -> String {
        let english = Bundle.module.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "en")
            .flatMap { NSDictionary(contentsOf: $0) as? [String: String] } ?? [:]
        let title = category.title
        return english.first { $0.value == title }?.key ?? title
    }

    @Test func jsonInventoryIsWellFormed() async throws {
        let pipe = Pipe()
        await JSONInventory.write(to: pipe.fileHandleForWriting)
        try pipe.fileHandleForWriting.close()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let payload = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let items = try #require(payload["items"] as? [[String: Any]])
        #expect(!items.isEmpty)
        #expect(items.allSatisfy { $0["id"] is String && $0["category"] is String && $0["safety"] is String })
        #expect(payload["totalBytes"] is NSNumber)
        #expect(payload["usedBytes"] is NSNumber)
        #expect(payload["physicalFreeBytes"] is NSNumber)
        #expect(payload["freeBytes"] == nil)
    }
}
