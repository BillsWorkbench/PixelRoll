import SwiftUI

struct CurveEditor: View {
    @Binding var points: [CurvePoint]
    let histogram: [[Double]]
    let channel: CurveChannel
    let interaction: (Bool) -> Void
    @State private var selected: Int?
    @State private var dragging = false
    @State private var levelStart: Double?
    @State private var grabOffset = CGPoint.zero
    private var color: Color { switch channel { case .rgb: .primary; case .red: .red; case .green: .green; case .blue: .blue } }
    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geometry in
                Canvas { context, size in
                    let bins: [Double] = {
                        let index: Int = switch channel { case .rgb: 3; case .red: 0; case .green: 1; case .blue: 2 }
                        return histogram.indices.contains(index) ? histogram[index] : []
                    }()
                    if let maximum = bins.max(), maximum > 0 {
                        var shape = Path()
                        shape.move(to: CGPoint(x: 0, y: size.height))
                        for (index, value) in bins.enumerated() {
                            shape.addLine(to: CGPoint(x: Double(index)/Double(max(1, bins.count-1))*size.width,
                                y: size.height*(1 - log1p(value)/log1p(maximum))))
                        }
                        shape.addLine(to: CGPoint(x: size.width, y: size.height)); shape.closeSubpath()
                        let tint: Color = channel == .rgb ? .secondary : color
                        context.fill(shape, with: .color(tint.opacity(0.16)))
                        context.stroke(shape, with: .color(tint.opacity(0.5)), lineWidth: 0.8)
                    }
                    var grid = Path()
                    for index in 1...3 {
                        let x = size.width * Double(index)/4, y = size.height * Double(index)/4
                        grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
                        grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    context.stroke(grid, with: .color(.gray.opacity(0.25)), lineWidth: 1)
                    let spline = CurveSpline(points: points)
                    var line = Path()
                    for index in 0...256 {
                        let x = Double(index)/256
                        let position = CGPoint(x: x*size.width, y: (1-spline.value(x))*size.height)
                        if index == 0 { line.move(to: position) } else { line.addLine(to: position) }
                    }
                    for (index, point) in points.enumerated() {
                        let position = CGPoint(x: point.x*size.width, y: (1-point.y)*size.height)
                        context.fill(Path(ellipseIn: CGRect(x: position.x-4, y: position.y-4, width: 8, height: 8)), with: .color(selected == index ? .accentColor : color))
                    }
                    context.stroke(line, with: .color(color), lineWidth: 1.5)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                    let x = min(1, max(0, event.location.x / geometry.size.width))
                    let y = min(1, max(0, 1-event.location.y / geometry.size.height))
                    if !dragging {
                        grabOffset = .zero
                        selected = points.indices.min(by: { distance(points[$0], event.startLocation, geometry.size) < distance(points[$1], event.startLocation, geometry.size) })
                        if let index = selected, distance(points[index], event.startLocation, geometry.size) > 16 {
                            guard points.count < 12, !points.contains(where: { abs($0.x-x) < 0.015 }) else { selected = nil; return }
                            var next = points; next.append(CurvePoint(x: x, y: y)); next.sort { $0.x < $1.x }
                            interaction(true); dragging = true; selected = next.firstIndex { $0.x == x }; points = next
                        } else {
                            if let index = selected {
                                grabOffset = CGPoint(x: points[index].x - event.startLocation.x / geometry.size.width,
                                                     y: points[index].y - (1-event.startLocation.y / geometry.size.height))
                            }
                            interaction(true); dragging = true
                        }
                    }
                    guard let index = selected, points.indices.contains(index) else { return }
                    var next = points
                    let lower = index == 0 ? 0 : points[index-1].x + 0.015
                    let upper = index == points.count-1 ? 1 : points[index+1].x - 0.015
                    let fixedX = min(upper, max(lower, x + grabOffset.x))
                    next[index] = CurvePoint(x: fixedX, y: min(1, max(0, y + grabOffset.y)))
                    if PhotoCurves.valid(next) { points = next }
                }.onEnded { _ in if dragging { interaction(false) }; dragging = false })
                .simultaneousGesture(TapGesture(count: 2).onEnded { points = PhotoCurves.identity; selected = nil })
                .accessibilityLabel(channel.rawValue + " curve with input histogram, \(points.count) control points")
            }.frame(height: 145).padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            inputLevels.padding(.horizontal, 8)
            HStack {
                Button("Remove Point") {
                    guard let selected, selected > 0, selected < points.count-1 else { return }
                    var next = points; next.remove(at: selected); points = next; self.selected = nil
                }.disabled(selected == nil || selected == 0 || selected == points.count-1)
                Spacer()
                Button("Reset Curve") { points = PhotoCurves.identity; selected = nil }
            }.controlSize(.small)
            Text("Drag black/white points inward · double-click to reset").font(.caption2).foregroundStyle(.secondary)
        }
        .onChange(of: channel) { _, _ in selected = nil }
        .onDisappear { if dragging { interaction(false) } }
    }
    private var inputLevels: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [.black, .white], startPoint: .leading, endPoint: .trailing)
                    .frame(height: 7).clipShape(RoundedRectangle(cornerRadius: 2))
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(.secondary.opacity(0.4)))
                levelHandle(white: false, width: geometry.size.width)
                levelHandle(white: true, width: geometry.size.width)
            }
        }.frame(height: 25)
    }
    private func moveLevel(white: Bool, to value: Double) {
        guard points.count >= 2, value.isFinite else { return }
        let index = white ? points.count-1 : 0
        let lower = white ? points[index-1].x + 0.015 : 0
        let upper = white ? 1 : points[1].x - 0.015
        var next = points
        next[index].x = min(upper, max(lower, value))
        if PhotoCurves.valid(next) { points = next }
    }
    private func levelHandle(white: Bool, width: Double) -> some View {
        let x = white ? points.last?.x ?? 1 : points.first?.x ?? 0
        return InputLevelTriangle()
            .fill(white ? Color.white : Color.black)
            .overlay(InputLevelTriangle().stroke(Color.gray, lineWidth: 1))
            .frame(width: 14, height: 14)
            .frame(width: 28, height: 25, alignment: .bottom)
            .contentShape(Rectangle())
            .offset(x: x * width - 14)
            .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                if !dragging { interaction(true); dragging = true }
                // Translation preserves the grab position instead of jumping to the pointer.
                if selected != (white ? points.count-1 : 0) || levelStart == nil {
                    selected = white ? points.count-1 : 0; levelStart = x
                }
                moveLevel(white: white, to: (levelStart ?? x) + event.translation.width / max(1, width))
            }.onEnded { _ in
                if dragging { interaction(false) }; dragging = false; levelStart = nil
            })
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                moveLevel(white: white, to: white ? 1 : 0)
            })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(white ? "White input point" : "Black input point")
            .accessibilityValue(String(format: "%.1f", x * 100))
            .accessibilityAdjustableAction { direction in
                moveLevel(white: white, to: x + (direction == .increment ? 0.01 : -0.01))
            }
            .help((white ? "White" : "Black") + " input point: drag to the histogram edge. Double-click to reset.")
    }
    private func distance(_ point: CurvePoint, _ location: CGPoint, _ size: CGSize) -> Double {
        hypot(point.x * size.width - location.x, (1-point.y) * size.height - location.y)
    }
}

private struct InputLevelTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}
