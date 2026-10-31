import AppKit
import SwiftUI

struct LargeFilesPage: View {
    @Environment(ScanModel.self) private var model
    @State private var confirmsTrash = false

    private var finder: LargeFilesModel { model.largeFiles }

    var body: some View {
        @Bindable var finder = finder
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(page: .largeFiles, subtitle: L("Big files in your folders, with how long since you last opened them.")) {
                    if finder.isScanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Button {
                            Task { await finder.scan() }
                        } label: {
                            Label(finder.hasScanned ? L("Rescan") : L("Scan"), systemImage: "magnifyingglass")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                roots
                HStack(spacing: 10) {
                    Picker(L("Minimum size"), selection: $finder.minimumBytes) {
                        ForEach(LargeFilesModel.sizeSteps, id: \.self) { step in
                            Text(L("Over %@", step.byteString)).tag(step)
                        }
                    }
                    .fixedSize()
                    Picker(L("Age"), selection: $finder.age) {
                        ForEach(LargeFilesModel.Age.allCases) { Text($0.title).tag($0) }
                    }
                    .fixedSize()
                    Picker(L("Kind"), selection: $finder.kind) {
                        ForEach(LargeFile.Kind.allCases) { kind in
                            Label(kind.title, systemImage: kind.symbol).tag(kind)
                        }
                    }
                    .fixedSize()
                    Spacer()
                }
                .labelsHidden()
                if let error = finder.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            .padding(24)

            Divider()
            list
            footer
        }
        .task {
            if !finder.hasScanned { await finder.scan() }
        }
        .alert(L("Move %lld files to the Trash?", finder.selectedFiles.count), isPresented: $confirmsTrash) {
            Button(L("Move to Trash"), role: .destructive) {
                Task { model.recordReleased(await finder.trashSelected()) }
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("%@ in total. Empty the Trash to free the space.", finder.selectedFiles.reduce(0) { $0 + $1.bytes }.byteString))
        }
    }

    private var roots: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(finder.roots, id: \.self) { root in
                HStack(spacing: 4) {
                    Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                    Text(root.lastPathComponent)
                    Button {
                        finder.removeRoot(root)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.bold))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(L("Stop scanning %@", root.lastPathComponent))
                }
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.6), in: Capsule())
                .help(root.abbreviatedPath)
            }
            Button {
                chooseFolder()
            } label: {
                Label(L("Add Folder…"), systemImage: "plus")
                    .font(.callout)
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private var list: some View {
        let files = finder.visibleFiles
        let largest = files.first?.bytes ?? 0
        if files.isEmpty {
            VStack(spacing: 8) {
                if finder.isScanning {
                    ProgressView()
                    Text(L("Looking through your folders…")).foregroundStyle(.secondary)
                } else {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text(finder.hasScanned ? L("No files match these filters.") : L("Scan to find large files."))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(files) { file in
                row(file, largest: largest)
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    private func row(_ file: LargeFile, largest: Int64) -> some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { finder.selectedIDs.contains(file.id) }, set: { _ in finder.toggle(file) })) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityLabel(L("Select %@", file.url.lastPathComponent))

            Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                .resizable()
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(file.url.deletingLastPathComponent().abbreviatedPath
                     + (file.lastUsed.map { " · " + L("Last opened %@", $0.formatted(.relative(presentation: .named))) } ?? ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                SizeBar(fraction: largest > 0 ? Double(file.bytes) / Double(largest) : 0, tint: .indigo)
                    .frame(maxWidth: 220)
            }
            Spacer(minLength: 8)
            Text(file.bytes.byteString)
                .font(.callout.weight(.medium))
                .monospacedDigit()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel(L("Reveal %@ in Finder", file.url.lastPathComponent))
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NSWorkspace.shared.open(file.url) }
    }

    private var footer: some View {
        let selected = finder.selectedFiles
        let visible = finder.visibleFiles
        return HStack(spacing: 12) {
            Text(L("%lld files · %@", visible.count, visible.reduce(0) { $0 + $1.bytes }.byteString))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            if !selected.isEmpty {
                Button(L("Clear")) { finder.selectedIDs = [] }
            }
            Button(role: .destructive) {
                confirmsTrash = true
            } label: {
                Label(L("Move %lld to Trash · %@", selected.count, selected.reduce(0) { $0 + $1.bytes }.byteString),
                      systemImage: "trash")
                    .monospacedDigit()
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(selected.isEmpty || finder.isDeleting)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = L("Add")
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(finder.addRoot)
    }
}
