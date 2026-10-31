import AppKit
import SwiftUI

struct UninstallerPage: View {
    enum Mode: String, CaseIterable, Identifiable {
        case apps, orphans

        var id: String { rawValue }
        var title: String { self == .apps ? L("Installed Apps") : L("Leftovers of Removed Apps") }
    }

    @Environment(ScanModel.self) private var model
    @State private var mode: Mode = .apps
    @State private var query = ""
    @State private var confirmsUninstall = false
    @State private var confirmsOrphans = false

    private var uninstaller: UninstallerModel { model.uninstaller }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(page: .uninstaller, subtitle: L("Remove an app together with the files it left around your Mac.")) {
                    Picker(L("Mode"), selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                if let error = uninstaller.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else if let notice = uninstaller.notice {
                    Label(notice, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            .padding(24)
            Divider()
            switch mode {
            case .apps: appsMode
            case .orphans: orphansMode
            }
        }
        .task { if uninstaller.apps.isEmpty { await uninstaller.loadApps() } }
    }

    // MARK: Apps

    private var filteredApps: [InstalledApp] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return uninstaller.apps }
        return uninstaller.apps.filter {
            $0.name.localizedCaseInsensitiveContains(text) || $0.bundleID.localizedCaseInsensitiveContains(text)
        }
    }

    private var appsMode: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(L("Search apps"), text: $query).textFieldStyle(.plain)
                }
                .padding(10)
                Divider()
                if uninstaller.isLoadingApps {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(filteredApps, selection: Binding(
                        get: { uninstaller.selectedApp?.id },
                        set: { id in uninstaller.selectedApp = uninstaller.apps.first { $0.id == id } }
                    )) { app in
                        HStack(spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                                .resizable()
                                .frame(width: 24, height: 24)
                            Text(app.name).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(app.bytes.byteString)
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .tag(app.id)
                    }
                    .listStyle(.sidebar)
                }
            }
            .frame(width: 280)
            Divider()
            appDetail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert(
            L("Uninstall %@?", uninstaller.selectedApp?.name ?? ""),
            isPresented: $confirmsUninstall
        ) {
            Button(L("Move to Trash"), role: .destructive) {
                Task { model.recordReleased(await uninstaller.uninstall()) }
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("%@ will quit if it is running. Everything ticked goes to the Trash, so it can be put back until you empty it.",
                   uninstaller.selectedApp?.name ?? ""))
        }
    }

    @ViewBuilder
    private var appDetail: some View {
        @Bindable var uninstaller = uninstaller
        if let app = uninstaller.selectedApp {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name).font(.title3.weight(.semibold))
                        Text([app.version.map { L("Version %@", $0) }, app.bundleID].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text(app.url.abbreviatedPath)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .padding(20)

                List {
                    Section {
                        Toggle(isOn: $uninstaller.removesAppBundle) {
                            HStack {
                                Text(L("The app itself"))
                                Spacer()
                                Text(app.bytes.byteString).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                    Section(uninstaller.isLoadingLeftovers
                            ? L("Looking for leftovers…")
                            : L("%lld leftovers found", uninstaller.leftovers.count)) {
                        ForEach(uninstaller.leftovers) { leftover in
                            leftoverRow(leftover, checked: uninstaller.checkedPaths.contains(leftover.id)) {
                                uninstaller.toggle(leftover)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)

                HStack {
                    Text(L("Name matches are left unticked; check them before removing."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive) {
                        confirmsUninstall = true
                    } label: {
                        Label(L("Uninstall · %@", uninstaller.uninstallBytes.byteString), systemImage: "trash")
                            .monospacedDigit()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(uninstaller.isRemoving || uninstaller.isLoadingLeftovers || uninstaller.uninstallBytes == 0)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "app.dashed")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text(L("Choose an app to see everything it installed."))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Orphans

    private var orphansMode: some View {
        VStack(spacing: 0) {
            if uninstaller.isLoadingOrphans {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(L("Checking app data against installed apps…")).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if uninstaller.orphans.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.seal").font(.system(size: 32)).foregroundStyle(.green)
                    Text(L("No leftovers from removed apps.")).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(uninstaller.orphans) { leftover in
                    leftoverRow(leftover, checked: uninstaller.checkedPaths.contains(leftover.id)) {
                        uninstaller.toggle(leftover)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
            HStack {
                Text(L("Folders named after apps that are no longer installed. Apps on external drives can look removed."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await uninstaller.loadOrphans() }
                } label: {
                    Label(L("Rescan"), systemImage: "arrow.clockwise")
                }
                .disabled(uninstaller.isLoadingOrphans)
                Button(role: .destructive) {
                    confirmsOrphans = true
                } label: {
                    Label(L("Move %lld to Trash · %@", uninstaller.checkedOrphans.count,
                            uninstaller.checkedOrphans.reduce(0) { $0 + $1.bytes }.byteString), systemImage: "trash")
                        .monospacedDigit()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(uninstaller.checkedOrphans.isEmpty || uninstaller.isRemoving)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
        .task { if uninstaller.orphans.isEmpty { await uninstaller.loadOrphans() } }
        .alert(L("Move %lld folders to the Trash?", uninstaller.checkedOrphans.count), isPresented: $confirmsOrphans) {
            Button(L("Move to Trash"), role: .destructive) {
                Task { model.recordReleased(await uninstaller.removeCheckedOrphans()) }
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("They can be put back from the Trash until you empty it."))
        }
    }

    private func leftoverRow(_ leftover: AppLeftover, checked: Bool, toggle: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { checked }, set: { _ in toggle() })) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel(L("Select %@", leftover.url.lastPathComponent))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(leftover.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Text(leftover.kind)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                    if leftover.match == .name {
                        Text(L("Name match"))
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.15), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
                Text(leftover.url.deletingLastPathComponent().abbreviatedPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(leftover.bytes.byteString)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([leftover.url])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel(L("Reveal %@ in Finder", leftover.url.lastPathComponent))
        }
        .padding(.vertical, 2)
    }
}
