import AppKit
import SwiftUI

struct SafariStorageCard: View {
    let model: SafariStorageModel
    let openFullDiskAccess: () -> Void

    @State private var pendingCleanup: SafariCleanupMode?
    @State private var showsAdvancedDetails = false

    var body: some View {
        GroupBox {
            if model.isScanning, model.report == nil {
                SafariScanningState()
            } else if let report = model.report {
                SafariStorageSummary(
                    report: report,
                    isCleaning: model.isCleaning,
                    lastResult: model.lastResult,
                    errorMessage: model.errorMessage,
                    pendingCleanup: $pendingCleanup,
                    showsAdvancedDetails: $showsAdvancedDetails,
                    onRescan: { Task { await model.scan() } },
                    onOpenFullDiskAccess: openFullDiskAccess,
                    onClean: { mode in Task { await model.clean(mode) } }
                )
            } else {
                Button {
                    Task { await model.scan() }
                } label: {
                    Label(L("Scan Safari Storage"), systemImage: "safari")
                }
            }
        } label: {
            Label(L("Safari Storage"), systemImage: "safari")
                .font(.headline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Safari Storage Cleaner"))
    }
}

private struct SafariScanningState: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(L("Scanning Safari…"))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

private struct SafariStorageSummary: View {
    let report: SafariStorageReport
    let isCleaning: Bool
    let lastResult: SafariCleanupResult?
    let errorMessage: String?
    @Binding var pendingCleanup: SafariCleanupMode?
    @Binding var showsAdvancedDetails: Bool
    let onRescan: () -> Void
    let onOpenFullDiskAccess: () -> Void
    let onClean: (SafariCleanupMode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SafariMetricRow(label: L("Total Safari Data"), bytes: report.totalBytes, emphasized: true)
            SafariMetricRow(label: L("Website Data"), bytes: report.websiteDataBytes)
            SafariMetricRow(label: L("Caches"), bytes: report.cacheBytes)
            if report.otherBytes > 0 {
                SafariMetricRow(label: L("Other"), bytes: report.otherBytes)
            }

            if report.permissionRestricted {
                SafariPermissionNotice(openSettings: onOpenFullDiskAccess)
            } else if let wal = report.largestWAL, let severity = report.walSeverity {
                SafariRunawayNotice(wal: wal, severity: severity)
            }

            if let result = lastResult {
                SafariCleanupResultView(result: result)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let mode = pendingCleanup {
                SafariCleanupConfirmation(mode: mode, report: report) {
                    pendingCleanup = nil
                } onConfirm: {
                    pendingCleanup = nil
                    onClean(mode)
                }
            } else {
                SafariActionBar(
                    report: report,
                    isDisabled: isCleaning || report.permissionRestricted,
                    onRecommended: { pendingCleanup = report.recommendedMode },
                    onWebsiteData: { pendingCleanup = .websiteData },
                    onQuick: { pendingCleanup = .quick },
                    onRescan: onRescan
                )
            }

            DisclosureGroup(L("Advanced Details"), isExpanded: $showsAdvancedDetails) {
                SafariAdvancedDetails(report: report)
            }
            .font(.caption)
        }
    }
}

private struct SafariMetricRow: View {
    let label: String
    let bytes: Int64
    var emphasized = false

    var body: some View {
        HStack {
            Text(label)
                .font(emphasized ? .subheadline.weight(.semibold) : .caption)
            Spacer()
            Text(bytes.byteString)
                .font(emphasized ? .subheadline.weight(.semibold) : .caption)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SafariRunawayNotice: View {
    let wal: SafariFile
    let severity: String

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("%@ LocalStorage detected", severity))
                    .font(.caption.weight(.semibold))
                Text("\(wal.displayName) · \(wal.bytes.byteString)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if wal.bytes >= 20 * 1024 * ProbeSupport.megabyte {
                    Text(L("This unusually large WebKit database is likely runaway Safari storage."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(7)
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 7))
        .accessibilityElement(children: .combine)
    }
}

private struct SafariPermissionNotice: View {
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(L("Safari storage cannot be fully inspected because macOS has restricted access."))
                    .font(.caption)
                Button(L("Open Full Disk Access Settings"), action: openSettings)
                    .controlSize(.small)
            }
        }
        .padding(7)
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 7))
    }
}

private struct SafariCleanupResultView: View {
    let result: SafariCleanupResult

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(L("Safari Cleaned Successfully"), systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
            SafariMetricRow(label: L("Before"), bytes: result.before.totalBytes)
            SafariMetricRow(label: L("After"), bytes: result.after.totalBytes)
            SafariMetricRow(label: L("Recovered"), bytes: result.recoveredBytes, emphasized: true)
            SafariMetricRow(label: L("Free on disk"), bytes: result.freeAfter)
        }
        .padding(7)
        .background(.green.opacity(0.1), in: .rect(cornerRadius: 7))
    }
}

private struct SafariActionBar: View {
    let report: SafariStorageReport
    let isDisabled: Bool
    let onRecommended: () -> Void
    let onWebsiteData: () -> Void
    let onQuick: () -> Void
    let onRescan: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(L("Clean Recommended Data"), action: onRecommended)
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(isDisabled || report.totalBytes == 0)
                .help(report.recommendedMode.title)
            Menu {
                Button(L("Clean Safari Website Data"), action: onWebsiteData)
                Button(L("Clear Safari Cache"), action: onQuick)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .disabled(isDisabled)
            .accessibilityLabel(L("Safari cleanup options"))
            Spacer()
            Button(action: onRescan) {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(isDisabled)
            .accessibilityLabel(L("Rescan Safari Storage"))
        }
        .controlSize(.small)
    }
}

private struct SafariCleanupConfirmation: View {
    let mode: SafariCleanupMode
    let report: SafariStorageReport
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private var bytes: Int64 {
        switch mode {
        case .quick: report.cacheBytes
        case .websiteData: report.websiteDataBytes
        case .targeted(let origin): report.origins.first(where: { $0.url == origin })?.bytes ?? 0
        }
    }

    private var requiresSafariQuit: Bool { SafariStorageCleaner.isSafariRunning }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L("Safari Website Data Cleanup"))
                .font(.caption.weight(.semibold))
            Text(L("This removes local website data and caches. You may be signed out or lose offline website data. Bookmarks and saved passwords are not deleted."))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(L("Space to recover: %@", bytes.byteString))
                .font(.caption)
                .monospacedDigit()
            if requiresSafariQuit {
                Text(L("Safari will quit before cleaning."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(L("Cancel"), action: onCancel)
                Button(requiresSafariQuit ? L("Quit Safari & Clean") : L("Clean Safari"), role: .destructive, action: onConfirm)
                    .tint(.red)
            }
            .controlSize(.small)
        }
        .padding(7)
        .background(.red.opacity(0.08), in: .rect(cornerRadius: 7))
    }
}

private struct SafariAdvancedDetails: View {
    let report: SafariStorageReport

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("Website origins: %lld", report.origins.count))
            if let origin = report.origins.first {
                Text(L("Largest website origin: %@", origin.bytes.byteString))
                Text(origin.url.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if !report.largestFiles.isEmpty {
                Text(L("Largest Safari Files"))
                    .font(.caption.weight(.semibold))
                    .padding(.top, 2)
                ForEach(report.largestFiles.prefix(4)) { file in
                    HStack {
                        Text(file.displayName)
                            .lineLimit(1)
                        Spacer()
                        Text(file.bytes.byteString)
                            .monospacedDigit()
                    }
                }
            }
        }
        .padding(.top, 4)
    }
}
