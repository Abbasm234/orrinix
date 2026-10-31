import SwiftUI

/// One category: an icon header with its total and a select-all toggle, then
/// its rows. Shared by the menu bar panel and the window.
struct CategoryGroupView: View {
    @Environment(ScanModel.self) private var model
    let category: StorageCategory
    let items: [StorageItem]
    let total: Int64
    @Binding var isExpanded: Bool
    var translucent = false
    /// This category's share of everything measured, drawn under its title.
    var share: Double = 0
    let onDelete: (StorageItem) -> Void

    private var largest: Int64 {
        items.compactMap(\.sizeBytes).max() ?? 0
    }

    private var selectable: [StorageItem] {
        items.filter { !$0.action.isManual }
    }

    private var allSelected: Bool {
        !selectable.isEmpty && selectable.allSatisfy { model.selectedIDs.contains($0.id) }
    }

    private var someSelected: Bool {
        selectable.contains { model.selectedIDs.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if isExpanded {
                Divider()
                ForEach(items) { item in
                    ItemRow(
                        item: item,
                        isBusy: model.busyItemIDs.contains(item.id),
                        isSelected: model.selectedIDs.contains(item.id),
                        onToggle: { model.toggleSelection(item) },
                        onDelete: { onDelete(item) },
                        onHide: { model.hide(item) },
                        fraction: largest > 0 ? Double(item.sizeBytes ?? 0) / Double(largest) : 0,
                        tint: category.tint
                    )
                }
            }
        }
        .card(padding: 12, translucent: translucent)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    TintedIcon(symbol: category.symbol, tint: category.tint)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(category.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(items.count == 1 ? L("1 item") : L("%lld items", items.count))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if share > 0 {
                                SizeBar(fraction: share, tint: category.tint, height: 3)
                                    .frame(width: 56)
                                Text(share.formatted(.percent.precision(.fractionLength(0))))
                                    .font(.caption2)
                                    .monospacedDigit()
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    Spacer(minLength: 8)
                    Text(total.byteString)
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("%@, %@", category.title, total.byteString))
            .accessibilityHint(isExpanded ? L("Collapse") : L("Expand"))

            if !selectable.isEmpty {
                SelectionCircle(
                    isOn: allSelected, isMixed: someSelected,
                    label: L("Select everything in %@", category.title)
                ) {
                    model.selectAll(in: category)
                }
                .help(L("Select everything in %@", category.title))
            }
        }
    }
}

// MARK: - Confirmation copy

extension ScanModel {
    func confirmationMessage(for item: StorageItem) -> String {
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

    var batchMessage: String {
        let selected = selectedItems
        let review = selected.filter { $0.safety == .review }
        let privileged = selected.filter { if case .privilegedScript = $0.action { true } else { false } }
        var lines = [L("Frees about %@. ", selectedBytes.byteString)]
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
