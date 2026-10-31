import AppKit
import SwiftUI

struct SettingsPage: View {
    @Environment(ScanModel.self) private var model

    var body: some View {
        Form {
            Section {
                PageHeader(page: .settings, subtitle: L("How Orrinix runs, and what it has been told to ignore."))
                    .padding(.vertical, 4)
            }
            Section(L("General")) {
                Toggle(L("Launch at login"), isOn: Binding(
                    get: { model.launchesAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                Toggle(isOn: Binding(
                    get: { model.shutsDownSimulatorsAtPowerOff },
                    set: { model.shutsDownSimulatorsAtPowerOff = $0 }
                )) {
                    Text(L("Shut down simulators at power off"))
                    Text(L("Booted simulators ignore the quit request and hold the shutdown for 33 seconds. This shuts them down first."))
                }
            }
            Section(L("Access")) {
                LabeledContent {
                    if model.hasFullDiskAccess {
                        Label(L("Granted"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button(L("Open Settings")) { NSWorkspace.shared.open(ScanModel.fullDiskAccessPane) }
                    }
                } label: {
                    Text(L("Full Disk Access"))
                    Text(L("Needed to measure Safari, Mail and other protected folders."))
                }
            }
            Section {
                if model.hiddenItems.isEmpty {
                    Text(L("No hidden items. Use the eye button on any row to hide it from future scans."))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.hiddenItems) { item in
                        HStack(spacing: 10) {
                            TintedIcon(symbol: item.category.symbol, tint: item.category.tint, size: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name).lineLimit(1)
                                Text(item.category.title).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(item.sizeBytes?.byteString ?? "—").monospacedDigit().foregroundStyle(.secondary)
                            Button(L("Show")) { model.unhide(item) }
                        }
                    }
                }
            } header: {
                HStack {
                    Text(L("Hidden Items"))
                    Spacer()
                    if model.hiddenCount > 0 {
                        Button(L("Show All")) { model.unhideAll() }
                            .buttonStyle(.link)
                    }
                }
            }
            Section(L("About")) {
                LabeledContent(L("Version"), value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                LabeledContent(L("Last scan"), value: model.lastScan?.formatted(date: .abbreviated, time: .shortened) ?? "—")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }
}
