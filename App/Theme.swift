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
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(tint.opacity(0.6), lineWidth: 1)
            )
            .cornerRadius(8)
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
struct ScanlineOverlay: View {
    var body: some View {
        Canvas { context, size in
            var y: CGFloat = 0
            while y < size.height {
                context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.black.opacity(0.08)))
                y += 3
            }
        }
        .allowsHitTesting(false)
    }
}
