import Foundation
import CoreGraphics

// Coordinates refer to the oriented, straightened image, with the origin at top left.
nonisolated struct PhotoCrop: Codable, Equatable, Sendable {
    enum Aspect: String, Codable, CaseIterable, Identifiable, Sendable {
        case free = "Freeform", original = "Original", threeTwo = "3:2", fourThree = "4:3", square = "1:1", wide = "16:9"
        var id: String { rawValue }
    }
    enum Corner: CaseIterable { case topLeft, topRight, bottomLeft, bottomRight
        var right: Bool { self == .topRight || self == .bottomRight }
        var bottom: Bool { self == .bottomLeft || self == .bottomRight }
    }
    var x = 0.0, y = 0.0, width = 1.0, height = 1.0
    var angle = 0.0
    var aspect = Aspect.original
    var flipped = false
    var valid: Bool {
        [x,y,width,height,angle].allSatisfy(\.isFinite) && x >= 0 && y >= 0 && width >= 0.02 && height >= 0.02 &&
        x + width <= 1.0000001 && y + height <= 1.0000001 && (-45...45).contains(angle)
    }
    var hasGeometry: Bool { x != 0 || y != 0 || width != 1 || height != 1 || angle != 0 }
    var preview: Self { var value = self; value.x = 0; value.y = 0; value.width = 1; value.height = 1; return value }
    func ratio(sourceAspect: Double) -> Double? {
        let value: Double
        switch aspect {
        case .free: return nil
        case .original: value = sourceAspect
        case .threeTwo: value = 3.0/2
        case .fourThree: value = 4.0/3
        case .square: value = 1
        case .wide: value = 16.0/9
        }
        return (flipped ? 1/value : value) / sourceAspect
    }
    func fitted(sourceAspect: Double) -> Self {
        guard let ratio = ratio(sourceAspect: sourceAspect), ratio.isFinite, ratio > 0 else { return self }
        var value = self
        value.width = min(width, height * ratio)
        value.height = value.width / ratio
        if min(value.width, value.height) < 0.02 {
            value.width = min(1, ratio); value.height = value.width / ratio
        }
        value.x = min(1-value.width, max(0, x+(width-value.width)/2))
        value.y = min(1-value.height, max(0, y+(height-value.height)/2))
        return value
    }
    func moved(dx: Double, dy: Double) -> Self {
        var value = self; value.x = min(1-width, max(0, x+dx)); value.y = min(1-height, max(0, y+dy)); return value
    }
    func resized(_ corner: Corner, dx: Double, dy: Double, sourceAspect: Double) -> Self {
        let anchorX = corner.right ? x : x+width, anchorY = corner.bottom ? y : y+height
        let maxW = corner.right ? 1-anchorX : anchorX, maxH = corner.bottom ? 1-anchorY : anchorY
        var w = min(maxW, max(0.02, width + (corner.right ? dx : -dx)))
        var h = min(maxH, max(0.02, height + (corner.bottom ? dy : -dy)))
        if let ratio = ratio(sourceAspect: sourceAspect) {
            // Use the dominant pointer motion, keeping the opposite corner fixed.
            w = abs(dx) >= abs(dy) ? w : h*ratio
            w = min(maxW, maxH*ratio, max(0.02, 0.02*ratio, w)); h = w/ratio
        }
        var value = self
        value.width = w; value.height = h
        value.x = corner.right ? anchorX : anchorX-w; value.y = corner.bottom ? anchorY : anchorY-h
        return value.valid ? value : self
    }
    // Same-aspect inscribed rectangle: no empty corners after rotating.
    static func straightenedSize(_ size: CGSize, angle: Double) -> CGSize {
        let radians = abs(angle) * .pi / 180, c = cos(radians), s = sin(radians)
        let scale = min(size.width/(size.width*c+size.height*s), size.height/(size.width*s+size.height*c))
        return CGSize(width: size.width*scale, height: size.height*scale)
    }
}
