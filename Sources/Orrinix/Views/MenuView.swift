import AppKit
import SwiftUI

struct MenuView: View {
    @Environment(ScanModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @State private var pendingDeletion: StorageItem?
    @State private var confirmsBatch = false
    @State private var searchQuery = ""

    private static let fullDiskAccessPane = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )!

    var body: some View {
        VStack(spacing: 0) {
            header
            if !model.hasFullDiskAccess {
                accessBanner
            }
            content
            Divider()
            if pendingDeletion != nil || confirmsBatch {
                confirmationBar
                Divider()
            }
            footer
        }
        .frame(width: 480, height: 740)
        .background(.regularMaterial)
        .task {
            model.refreshStorageMetrics()
            if !model.hasScanned, !model.isScanning { await model.scan() }
        }
    }

    // MARK: Confirmation

    /// Inline rather than a sheet: the menu bar panel is not a regular window,
    /// so sheets and confirmation dialogs never appear on it.
    private var confirmationBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let item = pendingDeletion {
                Text(L("Delete %@?", item.name))
                    .font(.subheadline.weight(.semibold))
                Text(confirmationMessage(for: item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L("Delete %lld items?", model.selectedItems.count))
                    .font(.subheadline.weight(.semibold))
                Text(batchMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(L("Cancel")) {
                    pendingDeletion = nil
                    confirmsBatch = false
                }
                .keyboardShortcut(.cancelAction)
                Button(role: .destructive) {
                    if let item = pendingDeletion {
                        Task { await model.reclaim(item) }
                    } else {
                        Task { await model.reclaimSelected() }
                    }
                    pendingDeletion = nil
                    confirmsBatch = false
                } label: {
                    Text(pendingDeletion != nil ? L("Delete") : L("Delete %lld items", model.selectedItems.count))
                }
                .keyboardShortcut(.defaultAction)
                .tint(.red)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.red.opacity(0.06))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "internaldrive.fill")
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(.cyan)
                .frame(width: 44, height: 44)
                .background(.cyan.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Orrinix")
                        .font(.system(size: 21, weight: .semibold, design: .rounded))
                }
                Text(model.isScanning ? model.phase : L("On this Mac"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if model.isScanning {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(L("Scanning"))
            } else {
                Button {
                    Task { await model.scan() }
                } label: {
                    Label(L("Rescan"), systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }
        }
        .padding(18)
    }

    // MARK: Full Disk Access

    private var accessBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Grant Full Disk Access once"))
                    .font(.caption.weight(.semibold))
                Text(L("Allow Orrinix to measure protected storage. Reopen the app after granting access."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(L("Open Settings")) {
                NSWorkspace.shared.open(Self.fullDiskAccessPane)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                overview
                SafariStorageCard(model: model.safari) {
                    NSWorkspace.shared.open(Self.fullDiskAccessPane)
                } onGlobalCleanupFinished: {
                    model.refreshStorageMetrics()
                }
                .groupBoxStyle(StorageGroupBoxStyle())
                HStack {
                    Text(L("Estimated System Data")).font(.headline)
                    Spacer()
                    Button(L("Select safe")) { model.selectAllSafe() }
                        .controlSize(.small)
                        .disabled(model.visibleItems.isEmpty)
                }
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(L("Filter items"), text: $searchQuery)
                        .textFieldStyle(.plain)
                }
                .padding(10)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                if model.visibleItems.isEmpty {
                    HStack {
                        if model.isScanning { ProgressView().controlSize(.small) }
                        Text(model.isScanning ? L("Measuring…") : L("Nothing to reclaim"))
                            .foregroundStyle(.secondary)
                    }.padding(.vertical, 16)
                } else if filteredCategories.isEmpty {
                    Text(L("No matching locations")).foregroundStyle(.secondary).padding(.vertical, 16)
                }
                ForEach(filteredCategories, id: \.category) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(group.category.title).font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(group.total.byteString).monospacedDigit().foregroundStyle(.secondary)
                        }
                        Divider()
                        ForEach(group.items) { item in
                            ItemRow(
                                item: item,
                                isBusy: model.busyItemIDs.contains(item.id),
                                isSelected: model.selectedIDs.contains(item.id),
                                onToggle: { model.toggleSelection(item) },
                                onDelete: { pendingDeletion = item },
                                onHide: { model.hide(item) }
                            )
                        }
                    }
                    .padding(14)
                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private var overview: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(L("Storage overview"), systemImage: "internaldrive")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text(model.isScanning ? L("Scanning") : L("On this Mac"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(model.storageMetrics.physicalFreeBytes.byteString)
                        .font(.system(size: 36, weight: .medium, design: .rounded))
                        .monospacedDigit()
                    Text(L("Free now")).foregroundStyle(.secondary)
                }
                Text(L("Estimated System Data: %@", model.measuredBytes.byteString))
                    .font(.caption).foregroundStyle(.secondary)
                    .help(L("System Data is an estimate. macOS uses private storage categorization and APFS accounting that may differ from third-party measurements."))
                if let reclaimable = model.storageMetrics.estimatedReclaimableBytes {
                    metricRow(L("Potentially reclaimable"), reclaimable.byteString)
                }
                if let potential = model.storageMetrics.potentialAvailableBytes {
                    metricRow(L("Potential available"), potential.byteString)
                }
                Divider()
                HStack {
                    Label(L("Measured locations"), systemImage: "folder")
                    Spacer()
                    Text("\(model.visibleItems.count)").monospacedDigit()
                }.font(.caption).foregroundStyle(.secondary)
                DisclosureGroup(L("Storage Diagnostics")) {
                    diagnostics
                }
                .font(.caption)
            }
            .padding(18)
            .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
            .modifier(OverviewSurface())
            HStack(spacing: 12) {
                metric(title: L("Safe to reclaim"), value: model.safeBytes.byteString, symbol: "checkmark.shield", tint: .green)
                metric(title: L("Reclaimed this session"), value: model.reclaimedBytes.byteString, symbol: "arrow.up.right", tint: .cyan)
            }
        }
    }

    private func metricRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var diagnostics: some View {
        let metrics = model.storageMetrics
        return VStack(alignment: .leading, spacing: 3) {
            diagnosticRow(L("Mount"), metrics.mountPoint.path)
            diagnosticRow(L("Total"), "\(metrics.totalBytes) bytes")
            diagnosticRow(L("Used"), "\(metrics.usedBytes) bytes")
            diagnosticRow(L("Physical free"), "\(metrics.physicalFreeBytes) bytes")
            diagnosticRow(L("Available for Important Usage"), metrics.importantUsageAvailableBytes.map { "\($0) bytes" } ?? L("Unavailable"))
            diagnosticRow(L("Available for Opportunistic Usage"), metrics.opportunisticAvailableBytes.map { "\($0) bytes" } ?? L("Unavailable"))
            diagnosticRow(L("Filesystem"), metrics.filesystemType ?? L("Unavailable"))
            diagnosticRow(L("Volume"), metrics.volumeName ?? L("Unavailable"))
        }
        .textSelection(.enabled)
        .padding(.top, 4)
    }

    private func diagnosticRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).monospaced().multilineTextAlignment(.trailing)
        }
    }

    private func metric(title: String, value: String, symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(value).font(.system(size: 23, weight: .medium, design: .rounded)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 16))
    }

    /// The scan can surface dozens of locations. Filtering stays local to the
    /// presentation layer, leaving the measured total and any selection intact.
    private var filteredCategories: [(category: StorageCategory, items: [StorageItem], total: Int64)] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.categories }
        return model.categories.compactMap { group in
            let matches = group.items.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                    || $0.detail.localizedCaseInsensitiveContains(query)
                    || group.category.title.localizedCaseInsensitiveContains(query)
            }
            guard !matches.isEmpty else { return nil }
            return (group.category, matches, matches.reduce(0) { $0 + ($1.sizeBytes ?? 0) })
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 6) {
            if let message = model.errorMessage {
                feedbackRow(message, symbol: "exclamationmark.triangle.fill", tint: .yellow) {
                    model.errorMessage = nil
                }
            } else if let message = model.notice {
                feedbackRow(message, symbol: "checkmark.circle.fill", tint: .green) {
                    model.notice = nil
                }
            }
            HStack {
                if model.selectedItems.isEmpty {
                    Text(L("Reclaimed this session: %@", model.reclaimedBytes.byteString))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Button(role: .destructive) {
                        confirmsBatch = true
                    } label: {
                        Text(L("Delete %lld selected · %@", model.selectedItems.count, model.selectedBytes.byteString))
                            .monospacedDigit()
                    }
                    .controlSize(.small)
                    .disabled(!model.busyItemIDs.isEmpty)
                    Button(L("Clear")) {
                        model.clearSelection()
                    }
                    .controlSize(.small)
                }
                if model.hiddenCount > 0 {
                    Button(L("%lld hidden", model.hiddenCount)) {
                        model.unhideAll()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help(L("Show all"))
                }
                Spacer()
                Button(L("Quit")) {
                    NSApplication.shared.terminate(nil)
                }
                .controlSize(.small)
                .keyboardShortcut("q")
            }
            HStack {
                Toggle(L("Shut down simulators at power off"), isOn: Binding(
                    get: { model.shutsDownSimulatorsAtPowerOff },
                    set: { model.shutsDownSimulatorsAtPowerOff = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(L("Booted simulators ignore the quit request and hold the shutdown for 33 seconds. This shuts them down first."))
                Toggle(L("Launch at login"), isOn: Binding(
                    get: { model.launchesAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // The list above is greedy; the footer must keep its full height so
        // a long error never overlaps the status line.
        .layoutPriority(1)
    }

    private func feedbackRow(_ message: String, symbol: String, tint: Color, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            ScrollView {
                Text(message)
                    .font(.caption)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 96)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(L("Dismiss"))
        }
        .padding(.bottom, 4)
    }

    private var authorBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles")
                .font(.caption.weight(.semibold))
            Text("Orrinix")
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
        .foregroundStyle(.secondary)
        .accessibilityLabel("Orrinix")
    }

    // MARK: Confirmation copy

    private func confirmationMessage(for item: StorageItem) -> String {
        let size = item.sizeBytes.map { L("Frees about %@. ", $0.byteString) } ?? ""
        switch item.safety {
        case .safe:
            return size + L("This is regenerated automatically when needed.")
        case .review:
            return size + item.detail + " " + L("It goes to the Trash first.")
        case .manual:
            return item.detail
        }
    }

    private var batchMessage: String {
        let selected = model.selectedItems
        let review = selected.filter { $0.safety == .review }
        let privileged = selected.filter { if case .privilegedScript = $0.action { true } else { false } }
        var lines = [L("Frees about %@. ", model.selectedBytes.byteString)]
        if !review.isEmpty {
            let names = review.prefix(4).map(\.name).joined(separator: ", ") + (review.count > 4 ? ", …" : "")
            lines.append(L("%lld marked Review go to the Trash: %@", review.count, names))
        }
        if privileged.count > 1 {
            lines.append(L("%lld items need root; the password is asked once.", privileged.count))
        } else if privileged.count == 1 {
            lines.append(L("1 item needs root; the password is asked once."))
        }
        return lines.joined(separator: "\n")
    }
}

private struct OverviewSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 20))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
        } else {
            content.background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
    }
}

private struct StorageGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            configuration.label
            configuration.content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 16))
    }
}
