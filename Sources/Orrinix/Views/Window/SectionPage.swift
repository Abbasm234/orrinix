import SwiftUI

/// Every category in one sidebar section, with search, a safety filter and
/// sorting.
struct SectionPage: View {
    enum SafetyFilter: String, CaseIterable, Identifiable {
        case all, safe, review, manual

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: L("All")
            case .safe: Safety.safe.label
            case .review: Safety.review.label
            case .manual: Safety.manual.label
            }
        }

        func matches(_ safety: Safety) -> Bool {
            switch self {
            case .all: true
            case .safe: safety == .safe
            case .review: safety == .review
            case .manual: safety == .manual
            }
        }
    }

    enum SortOrder: String, CaseIterable, Identifiable {
        case size, name

        var id: String { rawValue }
        var title: String { self == .size ? L("Size") : L("Name") }
    }

    @Environment(ScanModel.self) private var model
    let section: StorageSection
    let requestDelete: (StorageItem) -> Void

    @State private var query = ""
    @State private var filter: SafetyFilter = .all
    @State private var sort: SortOrder = .size
    @State private var collapsed: Set<StorageCategory> = []

    private var groups: [(category: StorageCategory, items: [StorageItem], total: Int64)] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return section.categories.compactMap { category in
            var items = model.visibleItems.filter { item in
                item.category == category && filter.matches(item.safety)
                    && (text.isEmpty || item.name.localizedCaseInsensitiveContains(text)
                        || item.detail.localizedCaseInsensitiveContains(text))
            }
            guard !items.isEmpty else { return nil }
            switch sort {
            case .size: items.sort { ($0.sizeBytes ?? -1) > ($1.sizeBytes ?? -1) }
            case .name: items.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
            return (category, items, items.reduce(0) { $0 + ($1.sizeBytes ?? 0) })
        }
        .sorted { $0.total > $1.total }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(page: .section(section), subtitle: subtitle) {
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
                controls
                let groups = groups
                if groups.isEmpty {
                    emptyState
                }
                ForEach(groups, id: \.category) { group in
                    CategoryGroupView(
                        category: group.category,
                        items: group.items,
                        total: group.total,
                        isExpanded: Binding(
                            get: { !collapsed.contains(group.category) },
                            set: { if $0 { collapsed.remove(group.category) } else { collapsed.insert(group.category) } }
                        ),
                        onDelete: requestDelete
                    )
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var subtitle: String {
        let total = model.total(of: section)
        let safe = model.safeTotal(of: section)
        guard model.hasScanned else { return model.phase }
        return L("%@ measured · %@ safe to remove", total.byteString, safe.byteString)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L("Filter items"), text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(L("Clear filter"))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator.opacity(0.7), lineWidth: 0.5))
            .frame(maxWidth: 280)

            Picker(L("Safety"), selection: $filter) {
                ForEach(SafetyFilter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 280)

            Picker(L("Sort by"), selection: $sort) {
                ForEach(SortOrder.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()

            Spacer()

            Menu {
                Button(L("Expand All")) { collapsed = [] }
                Button(L("Collapse All")) { collapsed = Set(section.categories) }
                Divider()
                Button(L("Select Safe in This Section")) {
                    let ids = model.visibleItems
                        .filter { $0.category.section == section && $0.safety == .safe && !$0.action.isManual }
                        .map(\.id)
                    model.selectedIDs.formUnion(ids)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel(L("More options"))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            if model.isScanning {
                ProgressView()
                Text(L("Measuring…")).foregroundStyle(.secondary)
            } else {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 32))
                    .foregroundStyle(.green)
                Text(query.isEmpty && filter == .all ? L("Nothing to reclaim") : L("No matching locations"))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}
