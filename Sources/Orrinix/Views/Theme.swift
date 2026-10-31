import AppKit
import SwiftUI

// MARK: - Category and section styling

extension StorageCategory {
    var symbol: String {
        switch self {
        case .snapshots: "clock.arrow.circlepath"
        case .xcode: "hammer.fill"
        case .simulators: "iphone"
        case .runtimes: "square.stack.3d.up.fill"
        case .packages: "shippingbox.fill"
        case .tools: "wrench.and.screwdriver.fill"
        case .editors: "chevron.left.forwardslash.chevron.right"
        case .logs: "doc.text.magnifyingglass"
        case .temp: "hourglass"
        case .docker: "cube.fill"
        case .vms: "desktopcomputer"
        case .trash: "trash.fill"
        case .backups: "ipad.and.iphone"
        case .shared: "person.2.fill"
        case .android: "candybarphone"
        case .browsers: "globe"
        case .chat: "bubble.left.and.bubble.right.fill"
        case .apps: "square.grid.2x2.fill"
        case .projects: "folder.fill.badge.gearshape"
        case .system: "gearshape.fill"
        case .other: "questionmark.folder.fill"
        }
    }

    var tint: Color {
        switch self {
        case .xcode: .blue
        case .simulators: .indigo
        case .runtimes: .purple
        case .packages: .brown
        case .tools: .teal
        case .editors: .purple
        case .docker: .cyan
        case .vms: .pink
        case .android: .green
        case .projects: .orange
        case .browsers: .blue
        case .chat: .pink
        case .apps: .orange
        case .snapshots: .teal
        case .logs: .gray
        case .temp: .mint
        case .trash: .gray
        case .backups: .green
        case .shared: .yellow
        case .system: .gray
        case .other: .secondary
        }
    }
}

extension StorageSection {
    var symbol: String {
        switch self {
        case .xcode: "hammer.fill"
        case .developer: "wrench.and.screwdriver.fill"
        case .apps: "square.grid.2x2.fill"
        case .system: "gearshape.fill"
        }
    }

    var tint: Color {
        switch self {
        case .xcode: .blue
        case .developer: .teal
        case .apps: .orange
        case .system: .purple
        }
    }
}

extension Safety {
    var tint: Color {
        switch self {
        case .safe: .green
        case .review: .orange
        case .manual: .secondary
        }
    }
}

// MARK: - Building blocks

/// A white SF Symbol on a tinted rounded square, as in System Settings.
struct TintedIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// The surface every grouped block sits on: the window's control background
/// with a hairline border, or a lighter translucent fill on the menu panel.
struct CardModifier: ViewModifier {
    var padding: CGFloat = 14
    var translucent = false

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
                if translucent {
                    shape.fill(.background.opacity(0.55))
                        .overlay(shape.strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
                } else {
                    shape.fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(shape.strokeBorder(.separator.opacity(0.7), lineWidth: 0.5))
                }
            }
    }
}

extension View {
    func card(padding: CGFloat = 14, translucent: Bool = false) -> some View {
        modifier(CardModifier(padding: padding, translucent: translucent))
    }
}

/// GroupBox with the card surface, for the Safari card.
struct CardGroupBoxStyle: GroupBoxStyle {
    var translucent = false

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            configuration.label
            configuration.content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .card(padding: 14, translucent: translucent)
    }
}

/// A thin proportional bar, used under rows to compare sizes at a glance.
struct SizeBar: View {
    let fraction: Double
    let tint: Color
    var height: CGFloat = 3

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary.opacity(0.6))
                Capsule().fill(tint.opacity(0.85))
                    .frame(width: max(proxy.size.width * min(max(fraction, 0), 1), fraction > 0 ? height : 0))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// The volume as one bar: what the scan explained, per section, then the
/// rest of the used space, then free space.
struct StorageBar: View {
    struct Segment: Identifiable {
        let id: String
        let title: String
        let bytes: Int64
        let color: Color
    }

    let metrics: StorageMetrics
    let segments: [Segment]
    var height: CGFloat = 12
    var showsLegend = true

    private var otherUsed: Int64 {
        max(metrics.usedBytes - segments.reduce(0) { $0 + $1.bytes }, 0)
    }

    private var allSegments: [Segment] {
        segments.filter { $0.bytes > 0 }
            + [Segment(id: "used", title: L("Everything else"), bytes: otherUsed, color: Color(nsColor: .tertiaryLabelColor))]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                let total = Double(max(metrics.totalBytes, 1))
                HStack(spacing: 1.5) {
                    ForEach(allSegments) { segment in
                        Rectangle()
                            .fill(segment.color.gradient)
                            .frame(width: max(proxy.size.width * Double(segment.bytes) / total - 1.5, 0))
                            .help("\(segment.title): \(segment.bytes.byteString)")
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5))
                .clipShape(Capsule())
            }
            .frame(height: height)
            .accessibilityElement()
            .accessibilityLabel(L("%@ used of %@", metrics.usedBytes.byteString, metrics.totalBytes.byteString))

            if showsLegend {
                legend
            }
        }
    }

    private var legend: some View {
        let items = allSegments + [Segment(id: "free", title: L("Free"), bytes: metrics.physicalFreeBytes, color: Color(nsColor: .quaternaryLabelColor))]
        return FlowLayout(spacing: 12, lineSpacing: 4) {
            ForEach(items) { segment in
                HStack(spacing: 5) {
                    Circle().fill(segment.color).frame(width: 7, height: 7)
                    Text(segment.title)
                        .foregroundStyle(.secondary)
                    Text(segment.bytes.byteString)
                        .monospacedDigit()
                }
                .font(.caption)
            }
        }
    }
}

/// Wraps its children onto as many lines as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// A large number with a caption, for the overview tiles.
struct MetricTile: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color
    var translucent = false

    var body: some View {
        HStack(spacing: 10) {
            TintedIcon(symbol: symbol, tint: tint, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .card(padding: 12, translucent: translucent)
        .accessibilityElement(children: .combine)
    }
}

extension ScanModel {
    /// Storage-bar segments for the scanned sections.
    var sectionSegments: [StorageBar.Segment] {
        StorageSection.allCases.map {
            StorageBar.Segment(id: $0.rawValue, title: $0.title, bytes: total(of: $0), color: $0.tint)
        }
    }
}
