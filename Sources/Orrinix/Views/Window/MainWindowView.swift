import AppKit
import SwiftUI

/// Pages of the full window's sidebar.
enum AppPage: Hashable, Sendable {
    case overview
    case section(StorageSection)
    case safari
    case largeFiles
    case uninstaller
    case settings

    var title: String {
        switch self {
        case .overview: L("Overview")
        case .section(let section): section.title
        case .safari: L("Safari")
        case .largeFiles: L("Large Files")
        case .uninstaller: L("Uninstaller")
        case .settings: L("Settings")
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .section(let section): section.symbol
        case .safari: "safari.fill"
        case .largeFiles: "doc.text.magnifyingglass"
        case .uninstaller: "xmark.app.fill"
        case .settings: "slider.horizontal.3"
        }
    }

    var tint: Color {
        switch self {
        case .overview: .accentColor
        case .section(let section): section.tint
        case .safari: .blue
        case .largeFiles: .indigo
        case .uninstaller: .red
        case .settings: .gray
        }
    }
}

struct MainWindowView: View {
    @Environment(ScanModel.self) private var model
    @State private var pendingDeletion: StorageItem?
    @State private var confirmsBatch = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 230, ideal: 250, max: 320)
        } detail: {
            detail
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
                .safeAreaInset(edge: .top, spacing: 0) { feedbackBanner }
                .safeAreaInset(edge: .bottom, spacing: 0) { selectionBar }
        }
        .task {
            if !model.hasScanned, !model.isScanning { await model.scan() }
        }
        .alert(
            pendingDeletion.map { L("Delete %@?", $0.name) } ?? "",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            presenting: pendingDeletion
        ) { item in
            Button(L("Delete"), role: .destructive) {
                Task { await model.reclaim(item) }
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: { item in
            Text(model.confirmationMessage(for: item))
        }
        .alert(L("Delete %lld items?", model.selectedItems.count), isPresented: $confirmsBatch) {
            Button(L("Delete %lld items", model.selectedItems.count), role: .destructive) {
                Task { await model.reclaimSelected() }
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(model.batchMessage)
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: Binding<AppPage?>(get: { model.page }, set: { if let page = $0 { model.page = page } })) {
            Section {
                sidebarRow(.overview, trailing: nil)
            }
            Section(L("Clean Up")) {
                ForEach(StorageSection.allCases) { section in
                    sidebarRow(.section(section), trailing: model.hasScanned ? model.total(of: section) : nil)
                }
                sidebarRow(.safari, trailing: model.safari.report?.totalBytes)
            }
            Section(L("Tools")) {
                sidebarRow(.largeFiles, trailing: nil)
                sidebarRow(.uninstaller, trailing: nil)
            }
            Section {
                sidebarRow(.settings, trailing: nil)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { sidebarFooter }
    }

    private func sidebarRow(_ page: AppPage, trailing bytes: Int64?) -> some View {
        HStack(spacing: 8) {
            TintedIcon(symbol: page.symbol, tint: page.tint, size: 20)
            Text(page.title)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let bytes, bytes > 0 {
                Text(bytes.byteString)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .tag(page)
    }

    private var sidebarFooter: some View {
        let metrics = model.storageMetrics
        let used = Double(metrics.usedBytes) / Double(max(metrics.totalBytes, 1))
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(metrics.volumeName ?? L("This Mac"))
                    .font(.caption.weight(.semibold))
                Spacer()
                if model.isScanning {
                    ProgressView().controlSize(.mini)
                }
            }
            SizeBar(fraction: used, tint: used > 0.9 ? .red : .accentColor, height: 5)
            Text(L("%@ free of %@", metrics.physicalFreeBytes.byteString, metrics.totalBytes.byteString))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(12)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch model.page {
        case .overview:
            OverviewPage(requestBatch: { confirmsBatch = true }, requestDelete: { pendingDeletion = $0 })
        case .section(let section):
            SectionPage(section: section, requestDelete: { pendingDeletion = $0 })
                .id(section)
        case .safari:
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PageHeader(page: .safari, subtitle: L("Website data and caches, cleaned with a strict allow-list."))
                    SafariStorageCard(model: model.safari) {
                        NSWorkspace.shared.open(ScanModel.fullDiskAccessPane)
                    } onGlobalCleanupFinished: {
                        model.refreshStorageMetrics()
                    }
                    .groupBoxStyle(CardGroupBoxStyle())
                }
                .padding(24)
                .frame(maxWidth: 820, alignment: .leading)
            }
            .task { if model.safari.report == nil { await model.safari.scan() } }
        case .largeFiles:
            LargeFilesPage()
        case .uninstaller:
            UninstallerPage()
        case .settings:
            SettingsPage()
        }
    }

    // MARK: Bars

    @ViewBuilder
    private var feedbackBanner: some View {
        if let message = model.errorMessage {
            banner(message, symbol: "exclamationmark.triangle.fill", tint: .orange) { model.errorMessage = nil }
        } else if let message = model.notice {
            banner(message, symbol: "checkmark.circle.fill", tint: .green) { model.notice = nil }
        }
    }

    private func banner(_ message: String, symbol: String, tint: Color, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(6)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel(L("Dismiss"))
        }
        .padding(12)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var selectionBar: some View {
        if !model.selectedItems.isEmpty, isCleanupPage {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                Text(L("%lld selected · %@", model.selectedItems.count, model.selectedBytes.byteString))
                    .monospacedDigit()
                Spacer()
                Button(L("Clear")) { model.clearSelection() }
                Button(role: .destructive) {
                    confirmsBatch = true
                } label: {
                    Label(L("Delete Selected"), systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!model.busyItemIDs.isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }

    private var isCleanupPage: Bool {
        switch model.page {
        case .overview, .section: true
        default: false
        }
    }
}

/// Title block at the top of each page.
struct PageHeader<Accessory: View>: View {
    let page: AppPage
    let subtitle: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            TintedIcon(symbol: page.symbol, tint: page.tint, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(page.title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            accessory
        }
    }
}

extension PageHeader where Accessory == EmptyView {
    init(page: AppPage, subtitle: String) {
        self.init(page: page, subtitle: subtitle) { EmptyView() }
    }
}

extension ScanModel {
    static let fullDiskAccessPane = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )!
}
