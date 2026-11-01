import Foundation

nonisolated struct CurvePoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
}

nonisolated enum CurveChannel: String, CaseIterable, Identifiable, Sendable {
    case rgb = "RGB", red = "Red", green = "Green", blue = "Blue"
    var id: String { rawValue }
}

nonisolated struct PhotoCurves: Codable, Equatable, Sendable {
    static let identity = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]
    var rgb = identity
    var red = identity
    var green = identity
    var blue = identity
    subscript(channel: CurveChannel) -> [CurvePoint] {
        get { switch channel { case .rgb: rgb; case .red: red; case .green: green; case .blue: blue } }
        set { switch channel { case .rgb: rgb = newValue; case .red: red = newValue; case .green: green = newValue; case .blue: blue = newValue } }
    }
    var valid: Bool { CurveChannel.allCases.allSatisfy { Self.valid(self[$0]) } }
    var isIdentity: Bool { CurveChannel.allCases.allSatisfy { self[$0].first == Self.identity.first && self[$0].last == Self.identity.last && self[$0].allSatisfy { abs($0.x - $0.y) < 0.000001 } } }
    static func valid(_ points: [CurvePoint]) -> Bool {
        guard (2...12).contains(points.count),
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }) else { return false }
        return zip(points, points.dropFirst()).allSatisfy { $1.x - $0.x >= 0.0149 }
    }
    static func value(_ x: Double, points: [CurvePoint]) -> Double { CurveSpline(points: points).value(x) }
    func lookupData() -> Data {
        var values = [Float](); values.reserveCapacity(512 * 3)
        let masterCurve = CurveSpline(points: rgb)
        let channels = [red, green, blue].map { CurveSpline(points: $0) }
        for index in 0..<512 {
            let master = masterCurve.value(Double(index) / 511)
            for curve in channels { values.append(Float(curve.value(master))) }
        }
        return values.withUnsafeBytes { Data($0) }
    }
}

// Shape-preserving cubic Hermite interpolation keeps the curve smooth without overshooting points.
nonisolated struct CurveSpline {
    let points: [CurvePoint]
    let slopes: [Double]
    init(points: [CurvePoint]) {
        self.points = points
        guard points.count >= 2 else { slopes = []; return }
        let spans = zip(points, points.dropFirst()).map { max(0.000001, $1.x - $0.x) }
        let deltas = zip(points, points.dropFirst()).enumerated().map { ($0.element.1.y - $0.element.0.y) / spans[$0.offset] }
        var slopes = Array(repeating: 0.0, count: points.count)
        slopes[0] = deltas[0]; slopes[points.count-1] = deltas.last!
        if points.count > 2 {
            for index in 1..<(points.count-1) where deltas[index-1] * deltas[index] > 0 {
                let w1 = 2 * spans[index] + spans[index-1]
                let w2 = spans[index] + 2 * spans[index-1]
                slopes[index] = (w1+w2) / (w1/deltas[index-1] + w2/deltas[index])
            }
        }
        for index in deltas.indices {
            if deltas[index] == 0 { slopes[index] = 0; slopes[index+1] = 0; continue }
            let a = slopes[index]/deltas[index], b = slopes[index+1]/deltas[index]
            let magnitude = hypot(a, b)
            if magnitude > 3 {
                slopes[index] = 3/magnitude * a * deltas[index]
                slopes[index+1] = 3/magnitude * b * deltas[index]
            }
        }
        self.slopes = slopes
    }
    func value(_ x: Double) -> Double {
        guard let first = points.first, let last = points.last else { return x }
        if x <= first.x { return first.y }; if x >= last.x { return last.y }
        for index in 0..<(points.count-1) where x >= points[index].x && x <= points[index+1].x {
            let a = points[index], b = points[index+1], h = b.x-a.x
            let t = (x-a.x)/h, t2 = t*t, t3 = t*t*t
            let y = (2*t3-3*t2+1)*a.y + (t3-2*t2+t)*h*slopes[index] + (-2*t3+3*t2)*b.y + (t3-t2)*h*slopes[index+1]
            return min(1, max(0, y))
        }
        return x
    }
}
