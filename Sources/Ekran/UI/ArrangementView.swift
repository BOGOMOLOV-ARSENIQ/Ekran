import AppKit
import SwiftUI

enum ArrangementWindowController {
    static func show() {
        WindowPresenter.shared.show(id: "arrangement", title: "Расположение дисплеев", size: NSSize(width: 680, height: 480)) {
            ArrangementView()
        }
    }
}

/// Visual display arrangement: drag displays, they snap edge to edge; double click makes a display main.
struct ArrangementView: View {
    struct Item: Identifiable {
        let id: CGDirectDisplayID
        let name: String
        let size: CGSize
        var origin: CGPoint

        var rect: CGRect { CGRect(origin: origin, size: size) }
    }

    @State private var items: [Item]
    @State private var mainID: CGDirectDisplayID
    @State private var dragging: CGDirectDisplayID?
    @State private var translation: CGSize = .zero
    @State private var isDirty = false

    init() {
        let (items, mainID) = Self.load()
        _items = State(initialValue: items)
        _mainID = State(initialValue: mainID)
    }

    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { geometry in
                let transform = Transform(rects: items.map(\.rect), size: geometry.size)
                ZStack(alignment: .topLeading) {
                    ForEach(items) { item in
                        let offset = dragging == item.id ? translation : .zero
                        let frame = transform.frame(for: item.rect).offsetBy(dx: offset.width, dy: offset.height)
                        Tile(name: item.name, size: item.size, isMain: item.id == mainID, isDragging: dragging == item.id)
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                            .gesture(
                                DragGesture(minimumDistance: 2)
                                    .onChanged { value in
                                        dragging = item.id
                                        translation = value.translation
                                    }
                                    .onEnded { value in drop(item.id, translation: value.translation, scale: transform.scale) }
                            )
                            .simultaneousGesture(TapGesture(count: 2).onEnded { makeMain(item.id) })
                            .contextMenu { Button("Сделать основным") { makeMain(item.id) } }
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .underPageBackgroundColor)))

            HStack {
                Text("Перетаскивайте дисплеи — они прилипают краями. Двойной щелчок делает дисплей основным.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Сбросить", action: reload).disabled(!isDirty)
                Button("Применить", action: apply).keyboardShortcut(.defaultAction).disabled(!isDirty)
            }
        }
        .padding()
    }

    // MARK: Model

    private static func load() -> ([Item], CGDirectDisplayID) {
        let manager = DisplayManager.shared
        let items = manager.displays
            .filter(\.isArranged)
            .map { display in
                let bounds = display.bounds
                return Item(id: display.id, name: manager.owner(of: display).name, size: bounds.size, origin: bounds.origin)
            }
        let mainID = items.first { $0.origin == .zero }?.id ?? items.first?.id ?? kCGNullDirectDisplay
        return (items, mainID)
    }

    private func reload() {
        (items, mainID) = Self.load()
        isDirty = false
    }

    private func drop(_ id: CGDirectDisplayID, translation: CGSize, scale: CGFloat) {
        defer {
            dragging = nil
            self.translation = .zero
        }
        guard let index = items.firstIndex(where: { $0.id == id }), scale > 0 else { return }
        let item = items[index]
        let proposed = CGPoint(x: item.origin.x + translation.width / scale, y: item.origin.y + translation.height / scale)
        let others = items.filter { $0.id != id }.map(\.rect)
        guard !others.isEmpty else { return }

        items[index].origin = Self.snap(size: item.size, proposed: proposed, others: others)
        normalize()
        isDirty = true
    }

    /// Nearest position that touches at least one other display without overlapping any.
    static func snap(size: CGSize, proposed: CGPoint, others: [CGRect]) -> CGPoint {
        let alignThreshold = max(size.width, size.height) * 0.04
        var candidates: [CGPoint] = []
        for other in others {
            let yRange = (other.minY - size.height + 1) ... (other.maxY - 1)
            let xRange = (other.minX - size.width + 1) ... (other.maxX - 1)
            func alignY(_ y: CGFloat) -> CGFloat {
                if abs(y - other.minY) < alignThreshold { return other.minY }
                if abs(y + size.height - other.maxY) < alignThreshold { return other.maxY - size.height }
                return y
            }
            func alignX(_ x: CGFloat) -> CGFloat {
                if abs(x - other.minX) < alignThreshold { return other.minX }
                if abs(x + size.width - other.maxX) < alignThreshold { return other.maxX - size.width }
                return x
            }
            let y = alignY(proposed.y.clamped(to: yRange))
            let x = alignX(proposed.x.clamped(to: xRange))
            candidates += [
                CGPoint(x: other.maxX, y: y), CGPoint(x: other.minX - size.width, y: y),
                CGPoint(x: x, y: other.maxY), CGPoint(x: x, y: other.minY - size.height),
            ]
        }
        let valid = candidates.filter { candidate in
            let rect = CGRect(origin: candidate, size: size)
            return !others.contains { other in
                let overlap = other.intersection(rect)
                return !overlap.isNull && overlap.width > 0.5 && overlap.height > 0.5
            }
        }
        let best = valid.min { lhs, rhs in
            hypot(lhs.x - proposed.x, lhs.y - proposed.y) < hypot(rhs.x - proposed.x, rhs.y - proposed.y)
        }
        return best.map { CGPoint(x: $0.x.rounded(), y: $0.y.rounded()) } ?? proposed
    }

    /// Keeps the main display at the global origin.
    private func normalize() {
        guard let main = items.first(where: { $0.id == mainID }) else { return }
        let shift = main.origin
        guard shift != .zero else { return }
        for index in items.indices {
            items[index].origin = CGPoint(x: items[index].origin.x - shift.x, y: items[index].origin.y - shift.y)
        }
    }

    private func makeMain(_ id: CGDirectDisplayID) {
        guard id != mainID else { return }
        mainID = id
        normalize()
        isDirty = true
    }

    private func apply() {
        let changed = items.filter { CGDisplayBounds($0.id).origin != $0.origin }
        guard !changed.isEmpty else {
            isDirty = false
            return
        }
        configureDisplays(.permanently) { config in
            for item in changed {
                CGConfigureDisplayOrigin(config, item.id, Int32(item.origin.x), Int32(item.origin.y))
            }
            return true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { reload() }
    }

    // MARK: Drawing

    private struct Transform {
        let scale: CGFloat
        let offset: CGPoint
        let union: CGRect

        init(rects: [CGRect], size: CGSize) {
            let union = rects.reduce(CGRect.null) { $0.union($1) }
            self.union = union.isNull ? .zero : union
            let padding: CGFloat = 36
            guard !union.isNull, union.width > 0, union.height > 0, size.width > padding * 2, size.height > padding * 2 else {
                scale = 1
                offset = .zero
                return
            }
            scale = min((size.width - padding * 2) / union.width, (size.height - padding * 2) / union.height, 0.18)
            offset = CGPoint(x: (size.width - union.width * scale) / 2, y: (size.height - union.height * scale) / 2)
        }

        func frame(for rect: CGRect) -> CGRect {
            CGRect(x: offset.x + (rect.minX - union.minX) * scale, y: offset.y + (rect.minY - union.minY) * scale,
                   width: rect.width * scale, height: rect.height * scale)
        }
    }

    private struct Tile: View {
        let name: String
        let size: CGSize
        let isMain: Bool
        let isDragging: Bool

        var body: some View {
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(isDragging ? 0.55 : 0.35))
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: isMain ? 2 : 1)
                if isMain {
                    Rectangle().fill(Color.white.opacity(0.85)).frame(height: 6).padding(.horizontal, 2).padding(.top, 2)
                }
                VStack(spacing: 2) {
                    Text(name).font(.system(size: 12, weight: .semibold)).lineLimit(2).multilineTextAlignment(.center)
                    Text(verbatim: "\(Int(size.width))×\(Int(size.height))").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .padding(6)
                .frame(maxHeight: .infinity)
            }
            .shadow(radius: isDragging ? 6 : 0)
        }
    }
}
