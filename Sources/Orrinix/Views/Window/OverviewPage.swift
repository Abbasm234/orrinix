import AppKit
import SwiftUI

struct OverviewPage: View {
    @Environment(ScanModel.self) private var model
    let requestBatch: () -> Void
    let requestDelete: (StorageItem) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(page: .overview, subtitle: subtitle) {
                    rescanButton
                }
                if !model.hasFullDiskAccess {
                    accessCallout
                }
                storageCard
                tiles
                sectionsCard
                largestCard
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var subtitle: String {
        if model.isScanning { return model.phase }
        if let last = model.lastScan {
            return L("Last scanned %@", last.formatted(.relative(presentation: .named)))
        }
        return L("What is using your disk, and what can safely go.")
    }

    private var rescanButton: some View {
        Group {
            if model.isScanning {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await model.scan() }
                } label: {
                    Label(L("Rescan"), systemImage: "arrow.clockwise")
                }
            }
        }
    }

    private var accessCallout: some View {
        HStack(spacing: 12) {
            TintedIcon(symbol: "lock.shield.fill", tint: .orange, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Grant Full Disk Access once"))
                    .font(.callout.weight(.semibold))
                Text(L("Allow Orrinix to measure protected storage. Reopen the app after granting access."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(L("Open Settings")) { NSWorkspace.shared.open(ScanModel.fullDiskAccessPane) }
        }
        .card()
    }

    private var storageCard: some View {
        let metrics = model.storageMetrics
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(metrics.physicalFreeBytes.byteString)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(L("free of %@", metrics.totalBytes.byteString))
                    .foregroundStyle(.secondary)
                Spacer()
                if let potential = metrics.potentialAvailableBytes, potential > metrics.physicalFreeBytes {
                    Text(L("Up to %@ once macOS purges caches", potential.byteString))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(L("macOS frees purgeable space on its own when it needs room."))
                }
            }
            StorageBar(metrics: metrics, segments: model.sectionSegments, height: 14)
            DisclosureGroup(L("Storage Diagnostics")) {
                StorageDiagnostics(metrics: metrics)
            }
            .font(.caption)
        }
        .card(padding: 18)
    }

    private var tiles: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
            MetricTile(title: L("Safe to reclaim"), value: model.safeBytes.byteString,
                       symbol: "checkmark.shield.fill", tint: .green)
            MetricTile(title: L("Estimated System Data"), value: model.measuredBytes.byteString,
                       symbol: "internaldrive.fill", tint: .blue)
            MetricTile(title: L("Measured locations"), value: "\(model.visibleItems.count)",
                       symbol: "folder.fill", tint: .indigo)
            MetricTile(title: L("Reclaimed this session"), value: model.reclaimedBytes.byteString,
                       symbol: "arrow.up.forward.circle.fill", tint: .teal)
        }
    }

    private var sectionsCard: some View {
        let largest = StorageSection.allCases.map { model.total(of: $0) }.max() ?? 0
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L("Where the space goes"))
                    .font(.headline)
                Spacer()
                Button {
                    model.selectAllSafe()
                    if !model.selectedItems.isEmpty { requestBatch() }
                } label: {
                    Label(L("Clean All Safe Items"), systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.safeBytes == 0 || model.isScanning || !model.busyItemIDs.isEmpty)
            }
            .padding(.bottom, 8)
            ForEach(StorageSection.allCases) { section in
                Button {
                    model.page = .section(section)
                } label: {
                    sectionRow(section, largest: largest)
                }
                .buttonStyle(.plain)
                if section != StorageSection.allCases.last {
                    Divider().padding(.leading, 40)
                }
            }
        }
        .card(padding: 16)
    }

    private func sectionRow(_ section: StorageSection, largest: Int64) -> some View {
        let total = model.total(of: section)
        let safe = model.safeTotal(of: section)
        return HStack(spacing: 12) {
            TintedIcon(symbol: section.symbol, tint: section.tint, size: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(section.title).font(.callout.weight(.medium))
                    Spacer()
                    Text(total.byteString).monospacedDigit()
                }
                SizeBar(fraction: largest > 0 ? Double(total) / Double(largest) : 0, tint: section.tint, height: 5)
                Text(safe > 0 ? L("%@ safe to remove", safe.byteString) : L("Nothing safe to remove automatically"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var largestCard: some View {
        let top = model.visibleItems
            .filter { $0.sizeBytes != nil }
            .sorted { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
            .prefix(8)
        let largest = top.first?.sizeBytes ?? 0
        return VStack(alignment: .leading, spacing: 10) {
            Text(L("Largest items"))
                .font(.headline)
            if top.isEmpty {
                Text(model.isScanning ? L("Measuring…") : L("Nothing to reclaim"))
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(top)) { item in
                HStack(alignment: .top, spacing: 10) {
                    TintedIcon(symbol: item.category.symbol, tint: item.category.tint, size: 20)
                        .padding(.top, 2)
                    ItemRow(
                        item: item,
                        isBusy: model.busyItemIDs.contains(item.id),
                        isSelected: model.selectedIDs.contains(item.id),
                        onToggle: { model.toggleSelection(item) },
                        onDelete: { requestDelete(item) },
                        onHide: { model.hide(item) },
                        fraction: largest > 0 ? Double(item.sizeBytes ?? 0) / Double(largest) : 0,
                        tint: item.category.tint
                    )
                }
            }
        }
        .card(padding: 16)
    }
}

/// Raw volume numbers, for when the summary does not match Finder.
struct StorageDiagnostics: View {
    let metrics: StorageMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            row(L("Mount"), metrics.mountPoint.path)
            row(L("Total"), "\(metrics.totalBytes) bytes")
            row(L("Used"), "\(metrics.usedBytes) bytes")
            row(L("Physical free"), "\(metrics.physicalFreeBytes) bytes")
            row(L("Available for Important Usage"), metrics.importantUsageAvailableBytes.map { "\($0) bytes" } ?? L("Unavailable"))
            row(L("Available for Opportunistic Usage"), metrics.opportunisticAvailableBytes.map { "\($0) bytes" } ?? L("Unavailable"))
            row(L("Filesystem"), metrics.filesystemType ?? L("Unavailable"))
            row(L("Volume"), metrics.volumeName ?? L("Unavailable"))
        }
        .textSelection(.enabled)
        .padding(.top, 4)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).monospaced().multilineTextAlignment(.trailing)
        }
    }
}
