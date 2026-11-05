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
    /// `file` is a large file shown on its own; `files` is the rest of
    /// the folder's loose files; `rest` folds the smallest folders.
    enum Kind: Hashable { case folder, file, rest, files }
    /// The same id as the Explorer row it stands for, so selection matches.
    let id: String
    let dirID: Int64?
    let name: String
    let bytes: Int64
    let locked: Bool
    let planned: Bool
    let kind: Kind
    var newest: Int64 = 0
    /// Display path of a `file` tile.
    var filePath: String?
    /// macOS's own folders, which can't be moved: drawn as land.
    var land = false
}

enum TreemapColoring: String, CaseIterable, Identifiable {
    case size = "Size"
    case age = "Age"
    var id: Self { self }

    var help: String {
        switch self {
        case .size: "Deeper tiles weigh more"
        case .age: "Deeper tiles have been untouched longer"
        }
    }
}

/// A flat treemap drawn in a single Canvas: one view no matter how many
/// tiles, so hovering and resizing stay smooth. Tiles are depth bands by
/// relative weight (or age), macOS's own folders are land, locked folders
/// are uncharted shoal. The squarified layout is worked out only when the
/// size or the tiles change, never while drawing or hovering.
struct TreemapCanvas: View {
    let tiles: [TreemapTile]
    var coloring: TreemapColoring = .size
    /// The tile whose Explorer row is selected.
    var selectedID: String?
    let onOpen: (TreemapTile) -> Void

    /// The tiles and the rectangles laid out for them, kept together so a
    /// draw never pairs new tiles with an old layout.
    struct Layout: Equatable {
        var tiles: [TreemapTile] = []
        var rects: [CGRect] = []
        var size: CGSize = .zero
        /// Bytes of the heaviest folder or file tile.
        var largest: Double = 1

        init() {}

        init(tiles: [TreemapTile], size: CGSize) {
            self.tiles = tiles
            self.size = size
            rects = TreemapLayout.layout(tiles.map { Double($0.bytes) }, in: CGRect(origin: .zero, size: size))
            largest = Double(tiles.filter { $0.kind == .folder || $0.kind == .file }.map(\.bytes).max() ?? 1)
        }

        func index(at point: CGPoint) -> Int? {
            rects.firstIndex { $0.contains(point) }
        }
    }

    @State private var layout = Layout()
    @State private var hovered: Int?
    @Environment(\.displayScale) private var displayScale

    /// `initialSize` lays the tiles out before the first geometry report:
    /// for snapshots, which render a single frame.
    init(tiles: [TreemapTile], coloring: TreemapColoring = .size, selectedID: String? = nil,
         initialSize: CGSize? = nil, onOpen: @escaping (TreemapTile) -> Void) {
        self.tiles = tiles
        self.coloring = coloring
        self.selectedID = selectedID
        self.onOpen = onOpen
        _layout = State(initialValue: initialSize.map { Layout(tiles: tiles, size: $0) } ?? Layout())
    }

    var body: some View {
        Canvas { context, _ in
            draw(in: &context)
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            guard size != layout.size else { return }
            layout = Layout(tiles: tiles, size: size)
            hovered = nil
        }
        .onChange(of: tiles) {
            layout = Layout(tiles: tiles, size: layout.size)
            hovered = nil
        }
        .overlay(alignment: .topLeading) { callout }
        .onContinuousHover { phase in
            let next: Int?
            switch phase {
            case .active(let point): next = layout.index(at: point)
            case .ended: next = nil
            }
            if next != hovered { Motion.with(Motion.feedback) { hovered = next } }
        }
        .gesture(SpatialTapGesture().onEnded { value in
            if let index = layout.index(at: value.location), layout.tiles.indices.contains(index) {
                onOpen(layout.tiles[index])
            }
        })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Folder map")
        .accessibilityValue(tiles.prefix(5).map { "\($0.name) \($0.bytes.bytes)" }.joined(separator: ", "))
        .accessibilityHint("The folder list below has the same items")
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext) {
        let hairline = 1 / max(displayScale, 1)
        for (index, tile) in layout.tiles.enumerated() where index < layout.rects.count {
            let rect = layout.rects[index].insetBy(dx: 1.5, dy: 1.5)
            guard rect.width > 1, rect.height > 1 else { continue }
            let radius = min(Theme.Radius.tile, min(rect.width, rect.height) / 3)
            let shape = Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
            let style = Self.style(for: tile, coloring: coloring, largest: layout.largest)
            context.fill(shape, with: .color(style.fill))
            if style.outlined {
                context.stroke(shape, with: .color(Theme.contour),
                               style: StrokeStyle(lineWidth: hairline, dash: tile.locked ? [3, 2] : []))
            }
            let inner = Path(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5), cornerRadius: max(radius - 1.5, 0),
                             style: .continuous)
            if tile.planned {
                // On the Cleanup List: a dashed line in the label's color,
                // which always contrasts with the tile.
                context.stroke(inner, with: .color(style.label.opacity(0.85)),
                               style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            }
            if tile.id == selectedID {
                context.stroke(shape, with: .color(style.label), lineWidth: hairline)
                context.stroke(inner, with: .color(style.label), lineWidth: hairline)
            } else if index == hovered {
                context.stroke(inner, with: .color(style.label.opacity(0.6)), lineWidth: hairline)
            }
            if rect.width > 64, rect.height > 34 {
                let name = Text(tile.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(style.label)
                context.draw(name, in: CGRect(x: rect.minX + 7, y: rect.minY + 5, width: rect.width - 14, height: 16))
                if rect.height > 48 {
                    let size = Text(tile.locked ? "Locked" : tile.bytes.bytes)
                        .font(.caption.italic().monospacedDigit())
                        .foregroundStyle(style.label.opacity(0.8))
                    context.draw(size, in: CGRect(x: rect.minX + 7, y: rect.minY + 21, width: rect.width - 14, height: 15))
                }
            }
        }
    }

    struct TileStyle {
        let fill: Color
        let label: Color
        /// Aggregates and locked folders get a contour line instead of depth.
        let outlined: Bool
    }

    /// Depth bands by weight relative to the heaviest tile (or by age),
    /// land for macOS's own folders, shoal for what isn't one measured
    /// thing. Labels flip to the ink plate's text color on the two deepest
    /// bands, which keeps them readable in day and night charts.
    static func style(for tile: TreemapTile, coloring: TreemapColoring, largest: Double, now: Date = .now) -> TileStyle {
        if tile.locked || tile.kind == .rest || tile.kind == .files {
            return TileStyle(fill: Theme.shoal, label: .secondary, outlined: true)
        }
        if tile.land {
            return TileStyle(fill: Theme.land, label: .primary, outlined: false)
        }
        let band = band(for: level(of: tile, coloring: coloring, largest: largest, now: now))
        return TileStyle(fill: Theme.depth[band], label: band >= 3 ? Theme.onInk : .primary, outlined: false)
    }

    /// 0...1: the square root of the share of the heaviest tile, so the
    /// bands spread instead of piling up in the shallowest; or, by age, a
    /// log scale where a year untouched is the deepest.
    static func level(of tile: TreemapTile, coloring: TreemapColoring, largest: Double, now: Date = .now) -> Double {
        switch coloring {
        case .size:
            return sqrt(min(max(Double(tile.bytes) / max(largest, 1), 0), 1))
        case .age:
            guard tile.newest > 0 else { return 0 }
            let days = max(now.timeIntervalSince1970 - Double(tile.newest), 0) / 86_400
            return min(log(1 + days) / log(1 + 365), 1)
        }
    }

    /// The band `Theme.depth(_:)` picks for a level.
    static func band(for level: Double) -> Int {
        let last = Theme.depth.count - 1
        return min(max(Int((min(max(level, 0), 1) * Double(last)).rounded()), 0), last)
    }

    // MARK: Hover callout

    /// The hovered tile's name and size on a small glass capsule at the
    /// tile's corner, kept inside the map.
    @ViewBuilder
    private var callout: some View {
        if let hovered, layout.tiles.indices.contains(hovered), hovered < layout.rects.count {
            let tile = layout.tiles[hovered]
            let rect = layout.rects[hovered]
            let bounds = layout.size
            HStack(spacing: 8) {
                Text(tile.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 220, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                if tile.locked {
                    Text("Locked").font(.callout).foregroundStyle(.secondary)
                } else {
                    Sounding(bytes: tile.bytes, font: Theme.soundingSmall)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .chartCapsule(interactive: false)
            .alignmentGuide(.leading) { d in -min(max(rect.minX + 6, 0), max(bounds.width - d.width, 0)) }
            .alignmentGuide(.top) { d in -min(max(rect.minY + 6, 0), max(bounds.height - d.height, 0)) }
            .allowsHitTesting(false)
            .transition(.opacity.animation(Motion.animation(Motion.exit)))
            .id(tile.id)
            .accessibilityHidden(true)
        }
    }
}

