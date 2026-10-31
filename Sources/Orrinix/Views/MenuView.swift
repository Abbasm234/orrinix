import AppKit
import SwiftUI

struct MenuView: View {
    @Environment(ScanModel.self) private var model
    @State private var pendingDeletion: StorageItem?
    @State private var confirmsBatch = false
    @State private var searchQuery = ""
    @State private var expanded: Set<StorageCategory> = []
    @State private var showsSafari = false
    @State private var section: StorageSection?
    @State private var showsSearch = false
    @FocusState private var searchFocused: Bool

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
        .background {
            ZStack(alignment: .top) {
                Rectangle().fill(.regularMaterial)
                PanelGlow()
            }
            .ignoresSafeArea()
        }
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
        HStack(spacing: 11) {
            TintedIcon(symbol: "internaldrive.fill", tint: .blue, size: 32)
                .shadow(color: .blue.opacity(0.35), radius: 6, y: 2)
            VStack(alignment: .leading, spacing: 1) {
                Text("Orrinix")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                HStack(spacing: 5) {
                    if model.isScanning {
                        ProgressView().controlSize(.mini)
                    }
                    Text(statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            circleButton("macwindow", label: L("Open Orrinix")) { openWindow() }
                .help(L("Open the full window with every tool"))
            circleButton("arrow.clockwise", label: L("Rescan")) {
                Task { await model.scan() }
            }
            .disabled(model.isScanning)
            .help(L("Rescan"))
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private var statusLine: String {
        if model.isScanning { return model.phase }
        if let last = model.lastScan {
            return L("Scanned %@", last.formatted(.relative(presentation: .named)))
        }
        return L("On this Mac")
    }

    private func circleButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(.background.opacity(0.6), in: Circle())
                .overlay(Circle().strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: Full Disk Access

    private var accessBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.orange)
            Text(L("Full Disk Access is off, so some folders can't be measured."))
                .font(.caption)
                .lineLimit(2)
            Spacer(minLength: 4)
            Button(L("Grant")) {
                NSWorkspace.shared.open(ScanModel.fullDiskAccessPane)
            }
            .controlSize(.small)
            .help(L("Allow Orrinix to measure protected storage. Reopen the app after granting access."))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                hero
                cleanButton
                chips
                if showsSearch {
                    searchField
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if section == nil || section == .apps {
                    safariGroup
                }
                categoryList
                toolsRow
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.never)
    }

    // MARK: Hero

    private var hero: some View {
        let metrics = model.storageMetrics
        let usedShare = Double(metrics.usedBytes) / Double(max(metrics.totalBytes, 1))
        return HStack(spacing: 18) {
            ZStack {
                RingChart(metrics: metrics, segments: model.sectionSegments, lineWidth: 12)
                VStack(spacing: 0) {
                    Text(metrics.physicalFreeBytes.byteString)
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                    Text(L("free"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(L("%@ used", usedShare.formatted(.percent.precision(.fractionLength(0)))))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 22)
            }
            .frame(width: 136, height: 136)
            .help(L("System Data is an estimate. macOS uses private storage categorization and APFS accounting that may differ from third-party measurements."))

            VStack(alignment: .leading, spacing: 4) {
                ForEach(StorageSection.allCases) { item in
                    legendRow(item)
                }
                Divider().padding(.vertical, 3)
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                        .frame(width: 14)
                    Text(L("Safe to reclaim"))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(model.safeBytes.byteString)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .font(.caption)
            }
        }
        .card(padding: 14, translucent: true)
        .animation(.snappy, value: model.safeBytes)
    }

    private func legendRow(_ item: StorageSection) -> some View {
        let isActive = section == item
        return Button {
            withAnimation(.snappy(duration: 0.25)) { section = isActive ? nil : item }
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(item.tint.gradient)
                    .frame(width: 9, height: 9)
                    .frame(width: 14)
                Text(item.shortTitle)
                    .foregroundStyle(isActive ? .primary : .secondary)
                Spacer(minLength: 4)
                Text(model.total(of: item).byteString)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .font(.caption.weight(isActive ? .semibold : .regular))
            .padding(.vertical, 2)
            .padding(.horizontal, 5)
            .background(isActive ? item.tint.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -5)
        .accessibilityLabel(L("%@, %@", item.title, model.total(of: item).byteString))
        .accessibilityHint(L("Show only this section"))
    }

    // MARK: Clean button

    private var cleanButton: some View {
        VStack(spacing: 6) {
            Button {
                model.selectAllSafe()
                if !model.selectedItems.isEmpty { confirmsBatch = true }
            } label: {
                HStack(spacing: 7) {
                    if model.isScanning || !model.busyItemIDs.isEmpty {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: model.safeBytes > 0 ? "sparkles" : "checkmark.seal.fill")
                    }
                    Text(cleanTitle)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            }
            .buttonStyle(GradientButtonStyle(colors: model.safeBytes > 0 ? [.blue, .purple] : [.green, .teal]))
            .disabled(model.safeBytes == 0 || model.isScanning || !model.busyItemIDs.isEmpty)
            if model.reclaimedBytes > 0 {
                Label(L("Reclaimed this session: %@", model.reclaimedBytes.byteString), systemImage: "arrow.up.forward.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.teal)
                    .monospacedDigit()
            }
        }
    }

    private var cleanTitle: String {
        if !model.busyItemIDs.isEmpty { return L("Cleaning…") }
        if model.isScanning && !model.hasScanned { return L("Measuring…") }
        if model.safeBytes > 0 { return L("Free up %@ safely", model.safeBytes.byteString) }
        return L("All tidy")
    }

    // MARK: Chips

    private var chips: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    chip(nil, title: L("All"), symbol: "square.grid.2x2", tint: .accentColor)
                    ForEach(StorageSection.allCases) { item in
                        chip(item, title: item.shortTitle, symbol: item.symbol, tint: item.tint)
                    }
                }
            }
            .scrollIndicators(.never)
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    showsSearch.toggle()
                    if !showsSearch { searchQuery = "" }
                }
                searchFocused = showsSearch
            } label: {
                Image(systemName: showsSearch ? "xmark" : "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(.background.opacity(0.6), in: Circle())
                    .overlay(Circle().strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showsSearch ? L("Clear filter") : L("Filter items"))
        }
    }

    private func chip(_ item: StorageSection?, title: String, symbol: String, tint: Color) -> some View {
        let isActive = section == item
        return Button {
            withAnimation(.snappy(duration: 0.25)) { section = item }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isActive ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                if isActive {
                    Capsule().fill(tint.gradient)
                } else {
                    Capsule().fill(.background.opacity(0.5))
                        .overlay(Capsule().strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L("Filter items"), text: $searchQuery)
                .textFieldStyle(.plain)
                .focused($searchFocused)
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
                        if let report = model.safari.report, report.totalBytes > 0 {
                            Text(report.totalBytes.byteString).font(.callout.weight(.semibold)).monospacedDigit()
                        } else if model.safari.report?.permissionRestricted == true {
                            Text(L("Needs access")).font(.caption).foregroundStyle(.secondary)
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
        let groups = filteredCategories.filter { section == nil || $0.category.section == section }
        let measured = Double(max(model.measuredBytes, 1))
        if model.visibleItems.isEmpty {
            HStack {
                if model.isScanning { ProgressView().controlSize(.small) }
                Text(model.isScanning ? L("Measuring…") : L("Nothing to reclaim"))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 16)
        } else if groups.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.green.gradient)
                Text(searchQuery.isEmpty ? L("All tidy here") : L("No matching locations"))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
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
                share: Double(group.total) / measured,
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
                    Text(model.reclaimedBytes > 0
                         ? L("Reclaimed this session: %@", model.reclaimedBytes.byteString)
                         : L("%lld locations measured", model.visibleItems.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Button(role: .destructive) {
                        confirmsBatch = true
                    } label: {
                        Label(L("Delete %lld selected · %@", model.selectedItems.count, model.selectedBytes.byteString),
                              systemImage: "trash.fill")
                            .monospacedDigit()
                            .padding(.horizontal, 12)
                    }
                    .buttonStyle(GradientButtonStyle(colors: [.red, .pink]))
                    .fixedSize()
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
