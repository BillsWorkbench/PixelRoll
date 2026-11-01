import SwiftUI
import AppKit

struct DevelopCanvas: NSViewRepresentable {
    let image: CGImage
    let actualPixels: Bool
    let photoID: URL
    var crop: PhotoCrop? = nil
    var cropChanged: ((PhotoCrop) -> Void)? = nil
    var sample: ((CGPoint) -> Void)? = nil

    func makeNSView(context: Context) -> DevelopScrollView { DevelopScrollView() }
    func updateNSView(_ view: DevelopScrollView, context: Context) { view.show(image, photoID: photoID, actualPixels: actualPixels, sample: sample, crop: crop, cropChanged: cropChanged) }
}

final class DevelopScrollView: NSScrollView {
    private let picture = PannablePhoto()
    private var bitmap: CGImage?
    private var photoID: URL?
    private var actualPixels = false
    private var recenter = true

    init() {
        super.init(frame: .zero)
        drawsBackground = true
        backgroundColor = NSColor(white: 0.09, alpha: 1)
        hasHorizontalScroller = true; hasVerticalScroller = true
        autohidesScrollers = true
        documentView = picture
        picture.setAccessibilityLabel("Develop photo — drag to pan at 100 percent")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ image: CGImage, photoID: URL, actualPixels: Bool, sample: ((CGPoint) -> Void)?, crop: PhotoCrop?, cropChanged: ((PhotoCrop) -> Void)?) {
        picture.sample = sample
        picture.crop = crop; picture.cropChanged = cropChanged
        window?.invalidateCursorRects(for: picture)
        if bitmap !== image {
            if self.photoID != photoID || bitmap?.width != image.width || bitmap?.height != image.height { recenter = true }
            self.photoID = photoID
            bitmap = image
            picture.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            picture.imageScaling = .scaleAxesIndependently
        }
        if self.actualPixels != actualPixels { self.actualPixels = actualPixels; recenter = true }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        guard let bitmap else { return }
        let viewport = contentView.bounds.size
        guard viewport.width > 0, viewport.height > 0 else { return }
        let scale = actualPixels ? 1 / (window?.backingScaleFactor ?? 2) :
            min(max(1, viewport.width - 40) / CGFloat(bitmap.width), max(1, viewport.height - 40) / CGFloat(bitmap.height))
        let size = NSSize(width: CGFloat(bitmap.width) * scale, height: CGFloat(bitmap.height) * scale)
        let canvas = NSSize(width: max(viewport.width, size.width), height: max(viewport.height, size.height))
        picture.frame = NSRect(origin: .zero, size: canvas)
        // The view draws into a centered rectangle; its document fills even a small image's viewport.
        picture.photoRect = NSRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2, width: size.width, height: size.height)
        if recenter {
            contentView.scroll(to: NSPoint(x: max(0, (canvas.width - viewport.width) / 2), y: max(0, (canvas.height - viewport.height) / 2)))
            reflectScrolledClipView(contentView)
            recenter = false
        }
        picture.needsDisplay = true
    }
}

final class PannablePhoto: NSImageView {
    var photoRect = NSRect.zero
    var sample: ((CGPoint) -> Void)?
    var crop: PhotoCrop?
    var cropChanged: ((PhotoCrop) -> Void)?
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .high
        image?.draw(in: photoRect, from: .zero, operation: .sourceOver, fraction: 1)
        if let crop {
            let rect = cropRect(crop)
            let shade = NSBezierPath(rect: photoRect); shade.append(NSBezierPath(rect: rect)); shade.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.6).setFill(); shade.fill()
            NSColor.white.setStroke(); let border = NSBezierPath(rect: rect); border.lineWidth = 1; border.stroke()
            NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: rect).addClip()
            let grid = NSBezierPath()
            for index in 1...5 {
                let fraction = Double(index)/6
                grid.move(to: NSPoint(x: rect.minX+rect.width*fraction, y: rect.minY)); grid.line(to: NSPoint(x: rect.minX+rect.width*fraction, y: rect.maxY))
                grid.move(to: NSPoint(x: rect.minX, y: rect.minY+rect.height*fraction)); grid.line(to: NSPoint(x: rect.maxX, y: rect.minY+rect.height*fraction))
            }
            NSColor.white.withAlphaComponent(0.5).setStroke(); grid.lineWidth = 0.5; grid.stroke()
            NSGraphicsContext.restoreGraphicsState()
            for corner in PhotoCrop.Corner.allCases {
                let point = cornerPoint(corner, rect: rect)
                let handle = NSBezierPath(roundedRect: NSRect(x: point.x-4, y: point.y-4, width: 8, height: 8), xRadius: 1, yRadius: 1)
                NSColor.white.setFill(); handle.fill(); NSColor.black.setStroke(); handle.lineWidth = 0.5; handle.stroke()
            }
        }
    }
    private func cropRect(_ crop: PhotoCrop) -> NSRect {
        NSRect(x: photoRect.minX+crop.x*photoRect.width, y: photoRect.minY+(1-crop.y-crop.height)*photoRect.height,
               width: crop.width*photoRect.width, height: crop.height*photoRect.height)
    }
    private func cornerPoint(_ corner: PhotoCrop.Corner, rect: NSRect) -> NSPoint {
        NSPoint(x: corner.right ? rect.maxX : rect.minX, y: corner.bottom ? rect.minY : rect.maxY)
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: crop != nil || sample != nil ? .crosshair : .openHand) }
    override func mouseDown(with event: NSEvent) {
        if let crop, let cropChanged {
            let start = convert(event.locationInWindow, from: nil), rect = cropRect(crop)
            let corner = PhotoCrop.Corner.allCases.min { a,b in
                let p = cornerPoint(a, rect: rect), q = cornerPoint(b, rect: rect)
                return hypot(p.x-start.x,p.y-start.y) < hypot(q.x-start.x,q.y-start.y)
            }!
            let handle = cornerPoint(corner, rect: rect)
            let resizing = hypot(handle.x-start.x,handle.y-start.y) <= 16
            guard resizing || rect.contains(start), photoRect.width > 0, photoRect.height > 0 else { return }
            while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                if next.type == .leftMouseUp { break }
                let point = convert(next.locationInWindow, from: nil)
                let dx = (point.x-start.x)/photoRect.width, dy = -(point.y-start.y)/photoRect.height
                let changed = resizing ? crop.resized(corner, dx: dx, dy: dy, sourceAspect: photoRect.width/photoRect.height) : crop.moved(dx: dx, dy: dy)
                self.crop = changed; needsDisplay = true; cropChanged(changed)
            }
            return
        }
        if let sample {
            let location = convert(event.locationInWindow, from: nil)
            guard photoRect.contains(location) else { return }
            sample(CGPoint(x: (location.x - photoRect.minX)/photoRect.width, y: (location.y - photoRect.minY)/photoRect.height))
            return
        }
        guard let scroll = enclosingScrollView else { return }
        let start = event.locationInWindow
        let origin = scroll.contentView.bounds.origin
        NSCursor.closedHand.push()
        defer { NSCursor.pop() }
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let delta = next.locationInWindow
            let proposed = NSPoint(x: origin.x - (delta.x - start.x), y: origin.y - (delta.y - start.y))
            let clip = scroll.contentView
            clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: proposed, size: clip.bounds.size)).origin)
            scroll.reflectScrolledClipView(clip)
        }
    }
}
