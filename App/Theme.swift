import SwiftUI

enum Theme {
    static let bg = Color.black
    static let green = Color(red: 0.20, green: 1.0, blue: 0.35)
    static let amber = Color(red: 1.0, green: 0.75, blue: 0.15)
    static let dimGreen = Theme.green.opacity(0.5)

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

struct TerminalPanel: ViewModifier {
    var tint: Color = Theme.green

    func body(content: Content) -> some View {
        content
            .background(Color.black)
            // Clip BEFORE stroking, and stroke with strokeBorder. The old order
            // (.overlay(stroke) then .cornerRadius) drew a 1pt line centred on
            // the shape's edge and then clipped everything outside that edge —
            // throwing away the outer half. Every panel border in the app was
            // rendering at half its intended weight. strokeBorder insets the
            // line fully inside the shape, so all 1pt of it survives.
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(tint.opacity(0.6), lineWidth: 1)
            )
            .shadow(color: tint.opacity(0.4), radius: 3)
    }
}

extension View {
    func terminalPanel(tint: Color = Theme.green) -> some View {
        modifier(TerminalPanel(tint: tint))
    }
}

/// Faint repeating horizontal lines over the whole popover, CRT-style.
/// A single Canvas draw call — cheap to lay out, unlike ~130 individual
/// Rectangle subviews, which visibly stuttered on every tab switch.
///
/// The lines are drawn in the phosphor colour, not in black. `Theme.bg` is pure
/// black and so is every panel fill, so black-at-8%-alpha scanlines were
/// mathematically invisible across almost the entire surface — the effect only
/// registered where it happened to cross green text or the amber button. The
/// Canvas was being re-rasterised on every layout pass to paint nothing.
struct ScanlineOverlay: View {
    var body: some View {
        Canvas { context, size in
            var y: CGFloat = 0
            while y < size.height {
                context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(Theme.green.opacity(0.035)))
                y += 3
            }
        }
        .allowsHitTesting(false)
        // A raster of thin lines is exactly the kind of shimmer that triggers
        // discomfort for motion-sensitive users when the window moves.
        .accessibilityHidden(true)
    }
}
