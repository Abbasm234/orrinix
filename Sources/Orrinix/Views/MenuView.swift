import AppKit
import SwiftUI

struct MenuView: View {
    @Environment(ScanModel.self) private var model
    @State private var pendingDeletion: StorageItem?
    @State private var confirmsBatch = false
    @State private var searchQuery = ""
    @State private var expanded: Set<StorageCategory> = []
    @State private var showsSafari = false

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

    private func openWindow(_ page: AppPage? = nil) {
        MainWindowController.shared.show(model: model, page: page)
    }

    // MARK: Confirmation

    /// Inline rather than a sheet: the menu bar panel is not a regular window,
    /// so sheets and confirmation dialogs never appear on it.
    private var confirmationBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let item = pendingDeletion {
                Text(L("Delete %@?", item.name))
                    .font(.subheadline.weight(.semibold))
                Text(model.confirmationMessage(for: item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L("Delete %lld items?", model.selectedItems.count))
                    .font(.subheadline.weight(.semibold))
                Text(model.batchMessage)
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
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.red.opacity(0.07))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            TintedIcon(symbol: "internaldrive.fill", tint: .accentColor, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text("Orrinix")
                    .font(.system(size: 17, weight: .semibold))
                Text(model.isScanning ? model.phase : L("On this Mac"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                openWindow()
            } label: {
                Label(L("Open Orrinix"), systemImage: "macwindow")
            }
            .controlSize(.small)
            .help(L("Open the full window with every tool"))
            if model.isScanning {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 24)
                    .accessibilityLabel(L("Scanning"))
            } else {
                Button {
                    Task { await model.scan() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .controlSize(.small)
                .help(L("Rescan"))
                .accessibilityLabel(L("Rescan"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: Full Disk Access

    private var accessBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield.fill")
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
                NSWorkspace.shared.open(ScanModel.fullDiskAccessPane)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    // MARK: Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                overview
                HStack(spacing: 10) {
                    MetricTile(title: L("Safe to reclaim"), value: model.safeBytes.byteString,
                               symbol: "checkmark.shield.fill", tint: .green, translucent: true)
                    MetricTile(title: L("Reclaimed this session"), value: model.reclaimedBytes.byteString,
                               symbol: "arrow.up.forward.circle.fill", tint: .teal, translucent: true)
                }
                HStack {
                    Text(L("Estimated System Data"))
                        .font(.headline)
                    Spacer()
                    Button(L("Select safe")) { model.selectAllSafe() }
                        .controlSize(.small)
                        .disabled(model.visibleItems.isEmpty)
                }
                .padding(.top, 4)
                searchField
                safariGroup
                categoryList
                toolsRow
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private var overview: some View {
        let metrics = model.storageMetrics
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(metrics.physicalFreeBytes.byteString)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(L("free of %@", metrics.totalBytes.byteString))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .help(L("System Data is an estimate. macOS uses private storage categorization and APFS accounting that may differ from third-party measurements."))
            StorageBar(metrics: metrics, segments: model.sectionSegments, height: 10)
        }
        .card(padding: 14, translucent: true)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L("Filter items"), text: $searchQuery)
                .textFieldStyle(.plain)
            if !searchQuery.isEmpty {
                Button { searchQuery = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(L("Clear filter"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
    }

    @ViewBuilder
    private var safariGroup: some View {
        if searchQuery.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { showsSafari.toggle() }
                } label: {
                    HStack(spacing: 10) {
                        TintedIcon(symbol: "safari.fill", tint: .blue)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(L("Safari Storage")).font(.subheadline.weight(.semibold))
                            Text(L("Website data and caches")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let total = model.safari.report?.totalBytes {
                            Text(total.byteString).font(.callout.weight(.medium)).monospacedDigit()
                        } else if model.safari.isScanning {
                            ProgressView().controlSize(.mini)
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(showsSafari ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showsSafari {
                    Divider()
                    SafariStorageCard(model: model.safari) {
                        NSWorkspace.shared.open(ScanModel.fullDiskAccessPane)
                    } onGlobalCleanupFinished: {
                        model.refreshStorageMetrics()
                    }
                    .groupBoxStyle(ContentOnlyGroupBoxStyle())
                }
            }
            .card(padding: 12, translucent: true)
        }
    }

    @ViewBuilder
    private var categoryList: some View {
        let groups = filteredCategories
        if model.visibleItems.isEmpty {
            HStack {
                if model.isScanning { ProgressView().controlSize(.small) }
                Text(model.isScanning ? L("Measuring…") : L("Nothing to reclaim"))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 16)
        } else if groups.isEmpty {
            Text(L("No matching locations")).foregroundStyle(.secondary).padding(.vertical, 16)
        }
        ForEach(groups, id: \.category) { group in
            CategoryGroupView(
                category: group.category,
                items: group.items,
                total: group.total,
                isExpanded: Binding(
                    get: { !searchQuery.isEmpty || expanded.contains(group.category) },
                    set: { if $0 { expanded.insert(group.category) } else { expanded.remove(group.category) } }
                ),
                translucent: true,
                onDelete: { pendingDeletion = $0 }
            )
        }
    }

    private var toolsRow: some View {
        HStack(spacing: 10) {
            toolButton(.largeFiles, subtitle: L("Find big, forgotten files"))
            toolButton(.uninstaller, subtitle: L("Remove apps completely"))
        }
        .padding(.top, 4)
    }

    private func toolButton(_ page: AppPage, subtitle: String) -> some View {
        Button {
            openWindow(page)
        } label: {
            HStack(spacing: 10) {
                TintedIcon(symbol: page.symbol, tint: page.tint, size: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text(page.title).font(.subheadline.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .card(padding: 10, translucent: true)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The scan can surface dozens of locations. Filtering stays local to the
    /// presentation layer, leaving the measured total and any selection intact.
    private var filteredCategories: [(category: StorageCategory, items: [StorageItem], total: Int64)] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let groups = query.isEmpty ? model.categories : model.categories.compactMap { group in
            let matches = group.items.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                    || $0.detail.localizedCaseInsensitiveContains(query)
                    || group.category.title.localizedCaseInsensitiveContains(query)
            }
            guard !matches.isEmpty else { return nil }
            return (group.category, matches, matches.reduce(0) { $0 + ($1.sizeBytes ?? 0) })
        }
        return groups.sorted { $0.total > $1.total }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 8) {
            if let message = model.errorMessage {
                feedbackRow(message, symbol: "exclamationmark.triangle.fill", tint: .orange) {
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
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)
                    .disabled(!model.busyItemIDs.isEmpty)
                    Button(L("Clear")) {
                        model.clearSelection()
                    }
                    .controlSize(.small)
                }
                if model.hiddenCount > 0 {
                    Button(L("%lld hidden", model.hiddenCount)) {
                        openWindow(.settings)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help(L("Manage hidden items"))
                }
                Spacer()
                Menu {
                    Toggle(L("Shut down simulators at power off"), isOn: Binding(
                        get: { model.shutsDownSimulatorsAtPowerOff },
                        set: { model.shutsDownSimulatorsAtPowerOff = $0 }
                    ))
                    Toggle(L("Launch at login"), isOn: Binding(
                        get: { model.launchesAtLogin },
                        set: { model.setLaunchAtLogin($0) }
                    ))
                    Divider()
                    Button(L("Settings…")) { openWindow(.settings) }
                } label: {
                    Image(systemName: "gearshape")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(L("Settings"))
                Button(L("Quit")) {
                    NSApplication.shared.terminate(nil)
                }
                .controlSize(.small)
                .keyboardShortcut("q")
            }
        }
        .padding(.horizontal, 16)
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
        .padding(8)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Shows only a GroupBox's content, for when the surrounding card already
/// has a header.
struct ContentOnlyGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.content.frame(maxWidth: .infinity, alignment: .leading)
    }
}
