import SwiftUI
import AppKit

// Capture modifiers from the actual mouse event, before SwiftUI's double-click delay.
struct PhotoClickTarget: NSViewRepresentable {
    var click: (NSEvent.ModifierFlags, Int) -> Void

    func makeNSView(context: Context) -> ClickView {
        let view = ClickView()
        view.click = click
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: ClickView, context: Context) { view.click = click }

    final class ClickView: NSView {
        var click: ((NSEvent.ModifierFlags, Int) -> Void)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { click?(event.modifierFlags, event.clickCount) }
    }
}
