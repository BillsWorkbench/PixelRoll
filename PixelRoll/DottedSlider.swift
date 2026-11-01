import SwiftUI

// Keep precision independent of tick density: hundreds of native ticks look like dashes.
struct DottedSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var editingChanged: (Bool) -> Void = { _ in }
    var body: some View {
        VStack(spacing: 0) {
            Slider(value: Binding(get: { min(range.upperBound, max(range.lowerBound, value)) }, set: { raw in
                let rounded = ((raw - range.lowerBound) / step).rounded() * step + range.lowerBound
                value = min(range.upperBound, max(range.lowerBound, rounded))
            }), in: range, onEditingChanged: editingChanged)
            Canvas { context, size in
                for index in 0...40 {
                    let x = 8 + (size.width - 16) * Double(index) / 40
                    context.fill(Path(ellipseIn: CGRect(x: x - 0.65, y: 1, width: 1.3, height: 1.3)), with: .color(.secondary.opacity(0.5)))
                }
            }.frame(height: 4).allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}
