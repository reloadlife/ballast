import SwiftUI

/// Squarified treemap (Bruls, Huizing & van Wijk): lays tiles out in rows
/// whose aspect ratios stay close to 1, so small folders remain clickable.
enum TreemapLayout {
    static func layout(_ values: [Double], in rect: CGRect) -> [CGRect] {
        var result = [CGRect](repeating: .zero, count: values.count)
        let sum = values.reduce(0, +)
        guard sum > 0, rect.width > 0, rect.height > 0 else { return result }

        let areas = values.map { $0 * rect.width * rect.height / sum }
        var remaining = rect
        var start = 0
        while start < areas.count {
            let side = min(remaining.width, remaining.height)
            var end = start + 1
            var best = worstRatio(areas[start..<end], side: side)
            while end < areas.count {
                let next = worstRatio(areas[start...end], side: side)
                if next > best { break }
                best = next
                end += 1
            }

            let rowArea = areas[start..<end].reduce(0, +)
            let thickness = rowArea / side
            let vertical = remaining.width >= remaining.height  // row becomes a column on the left
            var offset: CGFloat = 0
            for i in start..<end {
                let length = areas[i] / thickness
                result[i] = vertical
                    ? CGRect(x: remaining.minX, y: remaining.minY + offset, width: thickness, height: length)
                    : CGRect(x: remaining.minX + offset, y: remaining.minY, width: length, height: thickness)
                offset += length
            }
            remaining = vertical
                ? CGRect(x: remaining.minX + thickness, y: remaining.minY, width: remaining.width - thickness, height: remaining.height)
                : CGRect(x: remaining.minX, y: remaining.minY + thickness, width: remaining.width, height: remaining.height - thickness)
            start = end
        }
        return result
    }

    private static func worstRatio(_ row: ArraySlice<Double>, side: Double) -> Double {
        let sum = row.reduce(0, +)
        guard let largest = row.max(), let smallest = row.min(), smallest > 0 else { return .infinity }
        return max(side * side * largest / (sum * sum), sum * sum / (side * side * smallest))
    }
}

/// One tile in the Explorer's map.
struct TreemapTile: Identifiable, Hashable {
    enum Kind: Hashable { case folder, rest, files }
    let id: String
    let dirID: Int64?
    let name: String
    let bytes: Int64
    let locked: Bool
    let planned: Bool
    let kind: Kind
    var newest: Int64 = 0
}

enum TreemapColoring: String, CaseIterable, Identifiable {
    case size = "Size"
    case age = "Age"
    var id: Self { self }
}

/// A flat treemap drawn in a single Canvas: one view no matter how many
/// tiles, so hovering and resizing stay smooth.
struct TreemapCanvas: View {
    let tiles: [TreemapTile]
    var coloring: TreemapColoring = .size
    let onOpen: (TreemapTile) -> Void
    @State private var hovered: Int?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let rects = TreemapLayout.layout(tiles.map { Double($0.bytes) }, in: CGRect(origin: .zero, size: geo.size))
            let largest = Double(tiles.map(\.bytes).max() ?? 1)
            Canvas { context, _ in
                for (index, tile) in tiles.enumerated() {
                    let rect = rects[index].insetBy(dx: 1.5, dy: 1.5)
                    guard rect.width > 1, rect.height > 1 else { continue }
                    let shape = Path(roundedRect: rect, cornerRadius: min(7, min(rect.width, rect.height) / 3), style: .continuous)
                    context.fill(shape, with: .color(fill(for: tile, share: Double(tile.bytes) / largest)))
                    if tile.planned {
                        context.stroke(shape, with: .color(.red), style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                    }
                    if index == hovered {
                        context.stroke(shape, with: .color(.primary.opacity(0.7)), lineWidth: 2)
                    }
                    if rect.width > 64, rect.height > 34 {
                        let ink = labelColor(for: tile, share: Double(tile.bytes) / largest)
                        let label = Text(tile.name).font(.caption.weight(.semibold)).foregroundStyle(ink)
                        let size = Text(tile.bytes.bytes).font(.caption2).foregroundStyle(ink.opacity(0.8))
                        context.draw(label, in: CGRect(x: rect.minX + 7, y: rect.minY + 5, width: rect.width - 14, height: 16))
                        if rect.height > 48 {
                            context.draw(size, in: CGRect(x: rect.minX + 7, y: rect.minY + 21, width: rect.width - 14, height: 14))
                        }
                    }
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hovered = rects.firstIndex { $0.contains(point) }
                case .ended: hovered = nil
                }
            }
            .gesture(SpatialTapGesture().onEnded { value in
                if let index = rects.firstIndex(where: { $0.contains(value.location) }) { onOpen(tiles[index]) }
            })
            .help(hovered.map { tiles.indices.contains($0) ? "\(tiles[$0].name) — \(tiles[$0].bytes.bytes)" : "" } ?? "")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Folder map")
            .accessibilityValue(tiles.prefix(5).map { "\($0.name) \($0.bytes.bytes)" }.joined(separator: ", "))
        }
    }

    /// Size: the true accent hue, lightness stepping with size (lighter =
    /// smaller). Age: gray for recent, warming to orange for long-untouched.
    private func fill(for tile: TreemapTile, share: Double) -> Color {
        guard tile.kind == .folder, !tile.locked else { return Color(white: scheme == .dark ? 0.32 : 0.62) }
        switch coloring {
        case .size:
            let lightness = 1 - sqrt(max(share, 0))
            return scheme == .dark
                ? Color.accentColor.mix(with: .black, by: 0.5 * lightness)
                : Color.accentColor.mix(with: .white, by: 0.6 * lightness)
        case .age:
            let days = max(Date.now.timeIntervalSince1970 - Double(tile.newest), 0) / 86_400
            let t = tile.newest > 0 ? min(log(1 + days) / log(1 + 365), 1) : 0
            return Color(white: scheme == .dark ? 0.38 : 0.62).mix(with: Color(red: 0.90, green: 0.45, blue: 0.10), by: t)
        }
    }

    /// Dark text on pale tiles, white on deep ones, so labels stay readable
    /// without darkening the map.
    private func labelColor(for tile: TreemapTile, share: Double) -> Color {
        if scheme == .dark { return .white }
        guard tile.kind == .folder, !tile.locked, coloring == .size else { return .black.opacity(0.8) }
        return sqrt(max(share, 0)) > 0.55 ? .white : .black.opacity(0.8)
    }
}
