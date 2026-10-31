import Foundation

private let xcrun = "/usr/bin/xcrun"

// MARK: - Time Machine local snapshots

/// APFS keeps hourly Time Machine snapshots on the boot volume. Finder counts
/// their blocks as System Data and APFS refuses to report their size.
struct SnapshotProbe: StorageProbe {
    func probe() async -> [StorageItem] {
        guard let result = try? await Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"]) else { return [] }
        let snapshots = result.output
            .split(separator: "\n")
            .filter { $0.contains("com.apple.TimeMachine") }
        let dates = snapshots.compactMap { line -> String? in
            guard let suffix = line.split(separator: ".").last else { return nil }
            return suffix.count >= 19 ? String(suffix.prefix(19)) : nil
        }.sorted()
        let count = snapshots.count
        guard count > 0 else { return [] }

        let range = if let oldest = dates.first, let newest = dates.last {
            " Oldest: \(oldest). Newest: \(newest)."
        } else { "" }

        return [StorageItem(
            id: "snapshots",
            category: .snapshots,
            name: "\(count) local snapshot\(count == 1 ? "" : "s")",
            detail: "Hidden APFS snapshots kept between Time Machine runs. Size managed by APFS; the next backup recreates one.\(range)",
            sizeBytes: nil,
            safety: .safe,
            action: .privilegedScript("tmutil deletelocalsnapshots / ; tmutil thinlocalsnapshots / 9999999999999 4")
        )]
    }
}

// MARK: - Simulator devices

struct SimulatorProbe: StorageProbe {
    private let root = URL.home("Library/Developer/CoreSimulator")
    /// Devices nobody has booted for this long are offered for deletion
    /// rather than erasing.
    static let staleDays = 60

    func probe() async -> [StorageItem] {
        var items: [StorageItem] = []
        var cacheDirectories: [URL] = []
        var deviceCount = 0
        let staleCutoff = Date().addingTimeInterval(-Double(Self.staleDays) * 86_400)

        if let json = await ProbeSupport.json(xcrun, ["simctl", "list", "devices", "-j"]),
           let byRuntime = json["devices"] as? [String: [[String: Any]]] {
            for (runtime, devices) in byRuntime {
                for device in devices {
                    guard let name = device["name"] as? String,
                          let udid = device["udid"] as? String,
                          let dataPath = device["dataPath"] as? String else { continue }
                    let dataSize = (device["dataPathSize"] as? NSNumber)?.int64Value
                    let available = device["isAvailable"] as? Bool ?? false
                    let runtimeName = runtime.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
                    let lastUsed = (device["lastUsedAt"] as? String).flatMap(ProbeSupport.isoDate)

                    if !available {
                        items.append(StorageItem(
                            id: "sim-unavailable-\(udid)",
                            category: .simulators,
                            name: "Unavailable: \(name)",
                            detail: "Its runtime (\(runtimeName)) is no longer installed, so this device can never boot.",
                            sizeBytes: dataSize,
                            safety: .safe,
                            action: .command(executable: xcrun, arguments: ["simctl", "delete", udid]),
                            revealURL: URL(fileURLWithPath: dataPath)
                        ))
                        continue
                    }

                    deviceCount += 1
                    let data = URL(fileURLWithPath: dataPath)
                    cacheDirectories += [data.appending(path: "Library/Caches"), data.appending(path: "tmp")]
                        .filter(\.exists)

                    if lastUsed.map({ $0 < staleCutoff }) ?? true {
                        let when = lastUsed.map { "Last used \(ProbeSupport.relative($0))" } ?? "Never booted"
                        items.append(StorageItem(
                            id: "sim-stale-\(udid)",
                            category: .simulators,
                            name: "Unused: \(name)",
                            detail: "\(when) (\(runtimeName)). Deletes the device; Xcode can create it again.",
                            sizeBytes: dataSize,
                            safety: .review,
                            action: .steps([.shutdownSimulators, .command(executable: xcrun, arguments: ["simctl", "delete", udid])]),
                            revealURL: data
                        ))
                        continue
                    }

                    let when = lastUsed.map { " Last used \(ProbeSupport.relative($0))." } ?? ""
                    items.append(StorageItem(
                        id: "sim-erase-\(udid)",
                        category: .simulators,
                        name: "Erase \(name)",
                        detail: "Resets this \(runtimeName) simulator to factory state. Installed apps and their data are lost.\(when)",
                        sizeBytes: dataSize,
                        safety: .review,
                        action: .steps([.shutdownSimulators, .command(executable: xcrun, arguments: ["simctl", "erase", udid])]),
                        revealURL: data
                    ))
                }
            }
        }

        let sharedDyld = root.appending(path: "Caches/dyld")
        if sharedDyld.exists { cacheDirectories.append(sharedDyld) }

        if !cacheDirectories.isEmpty {
            var total: Int64 = 0
            for directory in cacheDirectories { total += await DiskSize.allocated(at: directory) }
            if total > 0 {
                items.insert(StorageItem(
                    id: "sim-caches",
                    category: .simulators,
                    name: "Device caches (\(deviceCount) devices)",
                    detail: "Per-device Caches and tmp plus the shared dyld cache. Rebuilt on the next boot.",
                    sizeBytes: total,
                    safety: .safe,
                    action: .steps([.shutdownSimulators, .emptyDirectories(cacheDirectories)]),
                    revealURL: root.appending(path: "Devices")
                ), at: 0)
            }
        }

        // macOS refuses to unlink anything under this folder, even for root
        // (verified on macOS 26: rm as uid 0 returns EPERM on an empty
        // subdirectory). Only CoreSimulator's own daemon can remove it, which
        // happens when the runtime it belongs to is deleted.
        let systemDyld = URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Caches/dyld")
        if let item = await ProbeSupport.directoryItem(
            id: "sim-system-dyld",
            category: .simulators,
            name: "System dyld cache",
            detail: "One shared cache per installed runtime, built by CoreSimulator. Protected by macOS: it goes away with its runtime, not on its own.",
            url: systemDyld,
            safety: .manual,
            action: .manual("Delete the runtime it belongs to (Simulator runtimes above), or:\nxcrun simctl runtime delete <UUID>\nThe cache is rebuilt when the runtime is installed again."),
            minimumBytes: 50 * ProbeSupport.megabyte
        ) {
            items.append(item)
        }

        return items
    }
}

// MARK: - Simulator runtimes

struct RuntimeProbe: StorageProbe {
    func probe() async -> [StorageItem] {
        guard let json = await ProbeSupport.json(xcrun, ["simctl", "runtime", "list", "-j"]) else { return [] }
        let devicesByRuntime = await deviceCounts()

        return json.compactMap { identifier, value -> StorageItem? in
            guard let runtime = value as? [String: Any],
                  runtime["deletable"] as? Bool ?? false,
                  let version = runtime["version"] as? String,
                  let build = runtime["build"] as? String else { return nil }
            let platform = platformName(runtime["platformIdentifier"] as? String ?? "")
            let size = (runtime["sizeBytes"] as? NSNumber)?.int64Value
            let lastUsed = (runtime["lastUsedAt"] as? String).flatMap(ProbeSupport.isoDate)
                .map { "Last used \(ProbeSupport.relative($0)). " } ?? ""
            let devices = (runtime["runtimeIdentifier"] as? String).flatMap { devicesByRuntime[$0] } ?? 0
            let usage = devices == 0
                ? "No simulators use it. "
                : devices == 1 ? "1 simulator stops working. " : "\(devices) simulators stop working. "

            return StorageItem(
                id: "runtime-\(identifier)",
                category: .runtimes,
                name: "\(platform) \(version) (\(build))",
                detail: "\(lastUsed)\(usage)Xcode > Settings > Components downloads it again.",
                sizeBytes: size,
                safety: .review,
                action: .deleteSimulatorRuntime(identifier: identifier, build: build),
                revealURL: (runtime["path"] as? String).map { URL(fileURLWithPath: $0) }
            )
        }
        .sorted { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
    }

    /// Available devices per runtime identifier.
    private func deviceCounts() async -> [String: Int] {
        guard let json = await ProbeSupport.json(xcrun, ["simctl", "list", "devices", "-j"]),
              let byRuntime = json["devices"] as? [String: [[String: Any]]] else { return [:] }
        return byRuntime.mapValues { devices in
            devices.filter { $0["isAvailable"] as? Bool ?? false }.count
        }
    }

    private func platformName(_ identifier: String) -> String {
        switch identifier {
        case "com.apple.platform.iphonesimulator": "iOS"
        case "com.apple.platform.watchsimulator": "watchOS"
        case "com.apple.platform.appletvsimulator": "tvOS"
        case "com.apple.platform.xrsimulator": "visionOS"
        default: identifier.components(separatedBy: ".").last ?? identifier
        }
    }
}

// MARK: - Xcode

/// Breaks Xcode's folders down to the level a developer actually decides at:
/// one DerivedData folder per project, one DeviceSupport folder per OS
/// version, one archive per build.
struct XcodeProbe: StorageProbe {
    private let root = URL.home("Library/Developer/Xcode")

    func probe() async -> [StorageItem] {
        var items: [StorageItem] = []
        items += await derivedData()
        items += await deviceSupport()
        items += await archives()

        let entries: [(String, URL, String, Safety)] = [
            ("SwiftUI preview devices", root.appending(path: "UserData/Previews"),
             "Simulators SwiftUI previews spin up. Recreated on demand.", .safe),
            ("Interface Builder devices", root.appending(path: "UserData/IB Support"),
             "Simulators Interface Builder renders with. Recreated on demand.", .safe),
            ("Documentation cache", root.appending(path: "DocumentationCache"),
             "Downloaded developer documentation. Fetched again when you open the docs.", .safe),
            ("Xcode Cloud & TestFlight products", root.appending(path: "Products"),
             "Builds downloaded for crash and energy reports. Downloaded again on demand.", .safe),
            ("Playground devices", .home("Library/Developer/XCPGDevices"),
             "Simulators used by playgrounds. Recreated on demand.", .safe),
            ("Xcode caches", .home("Library/Caches/com.apple.dt.Xcode"),
             "Download and index caches. Rebuilt as you use Xcode.", .safe),
            ("xcodebuild caches", .home("Library/Caches/com.apple.dt.xcodebuild"),
             "Command-line build caches.", .safe),
            ("Instruments caches", .home("Library/Caches/com.apple.dt.instruments"),
             "Symbol caches for Instruments traces.", .safe),
        ]
        for (name, url, detail, safety) in entries {
            if let item = await ProbeSupport.directoryItem(
                id: "xcode-\(url.abbreviatedPath)", category: .xcode, name: name, detail: detail,
                url: url, safety: safety, action: .emptyDirectories([url]), minimumBytes: ProbeSupport.megabyte
            ) {
                items.append(item)
            }
        }

        let active = (try? await Shell.run("/usr/bin/xcode-select", ["-p"]))?.output
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        for app in URL(fileURLWithPath: "/Applications").children()
        where app.lastPathComponent.hasPrefix("Xcode") && app.pathExtension == "app" && !active.hasPrefix(app.path) {
            if let item = await ProbeSupport.directoryItem(
                id: "xcode-app-\(app.lastPathComponent)", category: .xcode,
                name: "Inactive \(app.lastPathComponent)",
                detail: "Not the selected developer directory (\(active)).",
                url: app, safety: .review, action: .removePaths([app])
            ) {
                items.append(item)
            }
        }

        return items
    }

    /// One item per project. Xcode records the workspace each folder belongs
    /// to, so folders for projects that were moved or deleted are flagged.
    private func derivedData() async -> [StorageItem] {
        let derivedData = root.appending(path: "DerivedData")
        var items: [StorageItem] = []
        for folder in derivedData.children() where folder.isDirectory {
            let folderName = folder.lastPathComponent
            let name: String
            let detail: String
            if folderName.hasSuffix(".noindex") {
                let base = folderName.replacingOccurrences(of: ".noindex", with: "")
                name = "Shared \(base)"
                detail = "Shared by every project. Rebuilt on the next build."
            } else {
                let info = NSDictionary(contentsOf: folder.appending(path: "info.plist")) as? [String: Any]
                let workspace = (info?["WorkspacePath"] as? String).map { URL(fileURLWithPath: $0) }
                let project = workspace?.deletingPathExtension().lastPathComponent
                    ?? folderName.split(separator: "-").dropLast().joined(separator: "-")
                let lastBuilt = (info?["LastAccessedDate"] as? Date).map { " Last opened \(ProbeSupport.relative($0))." } ?? ""
                if let workspace, !workspace.exists {
                    name = "Orphaned: \(project)"
                    detail = "\(workspace.abbreviatedPath) no longer exists, so nothing will use this again.\(lastBuilt)"
                } else {
                    name = project.isEmpty ? folderName : project
                    detail = "\(workspace?.abbreviatedPath ?? folderName). Build products and index; rebuilt on the next build.\(lastBuilt)"
                }
            }
            if let item = await ProbeSupport.directoryItem(
                id: "xcode-dd-\(folderName)", category: .xcode, name: "DerivedData: \(name)", detail: detail,
                url: folder, safety: .safe, action: .removePaths([folder]), minimumBytes: ProbeSupport.megabyte
            ) {
                items.append(item)
            }
        }
        return items.sorted { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
    }

    /// iOS, watchOS, tvOS, visionOS and macOS DeviceSupport, one item per OS
    /// version. Only the newest version per platform is usually still needed.
    private func deviceSupport() async -> [StorageItem] {
        var items: [StorageItem] = []
        for platformFolder in root.children() where platformFolder.lastPathComponent.hasSuffix("DeviceSupport") {
            let platform = platformFolder.lastPathComponent.replacingOccurrences(of: " DeviceSupport", with: "")
            let versions = platformFolder.children()
                .filter(\.isDirectory)
                .map { ($0, ProbeSupport.modified($0) ?? .distantPast) }
                .sorted { $0.1 > $1.1 }
            for (index, (version, modified)) in versions.enumerated() {
                let age = modified == .distantPast ? "" : " Copied \(ProbeSupport.relative(modified))."
                let note = index == 0
                    ? "Newest \(platform) symbols on this Mac."
                    : "Older \(platform) symbols. Only needed to debug a device still on this version."
                if let item = await ProbeSupport.directoryItem(
                    id: "xcode-ds-\(platformFolder.lastPathComponent)-\(version.lastPathComponent)", category: .xcode,
                    name: "\(platform) DeviceSupport \(version.lastPathComponent)",
                    detail: "\(note)\(age) Copied again on the next connection.",
                    url: version, safety: .safe, action: .removePaths([version]), minimumBytes: ProbeSupport.megabyte
                ) {
                    items.append(item)
                }
            }
        }
        return items.sorted { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
    }

    /// One item per .xcarchive, named from its Info.plist.
    private func archives() async -> [StorageItem] {
        var items: [StorageItem] = []
        for day in root.appending(path: "Archives").children() where day.isDirectory {
            for archive in day.children() where archive.pathExtension == "xcarchive" {
                let info = NSDictionary(contentsOf: archive.appending(path: "Info.plist")) as? [String: Any]
                let properties = info?["ApplicationProperties"] as? [String: Any]
                let title = info?["Name"] as? String ?? archive.deletingPathExtension().lastPathComponent
                let version = (properties?["CFBundleShortVersionString"] as? String).map { " \($0)" } ?? ""
                let build = (properties?["CFBundleVersion"] as? String).map { " (\($0))" } ?? ""
                let created = (info?["CreationDate"] as? Date) ?? ProbeSupport.modified(archive)
                let age = created.map { "Archived \(ProbeSupport.relative($0)). " } ?? ""
                if let item = await ProbeSupport.directoryItem(
                    id: "xcode-archive-\(archive.path)", category: .xcode,
                    name: "Archive: \(title)\(version)\(build)",
                    detail: "\(age)Keep it while you still need its dSYMs to symbolicate crashes.",
                    url: archive, safety: .review, action: .removePaths([archive])
                ) {
                    items.append(item)
                }
            }
        }
        return items.sorted { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
    }
}
