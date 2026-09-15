import SwiftUI

/// `.plain` hit-tests a button against what it actually *draws*.
///
/// That is fine for a button whose label is a filled, opaque shape, and wrong for the two shapes
/// this app uses most: a navigation row with a `Color.clear` background and a `Spacer()` in the
/// middle, and a bare `Image(systemName:)`. In the first, only the letters and glyph strokes
/// respond — the padding and the whole empty centre are dead. In the second, the target is the
/// strokes of the symbol, so a click that lands between the strokes of a thin glyph does nothing
/// at all, which reads to the user as "the icon is broken".
///
/// This behaves like `.plain` but hit-tests the button's full declared frame. Prefer it for any
/// borderless control; keep `.plain` only where the label genuinely fills its frame.
public struct HitTestablePlainButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // Declared on the style rather than at each call site so the rule is stated once.
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1.0)
    }
}

extension ButtonStyle where Self == HitTestablePlainButtonStyle {
    /// Borderless like `.plain`, but clickable across the button's whole frame.
    public static var hitTestable: HitTestablePlainButtonStyle { HitTestablePlainButtonStyle() }
}
