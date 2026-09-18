import SwiftUI
import AppKit

extension View {
    /// Run `action` when `value` changes.
    ///
    /// Wraps SwiftUI's zero-parameter `onChange`, which replaced the two-parameter form deprecated
    /// in macOS 14. This existed as an availability shim with a pre-14 fallback, but the app's
    /// deployment target *is* macOS 14 — so that branch could never run, and call sites that
    /// wanted a non-Int value reached for the deprecated API directly instead.
    public func onValueChanged<Value: Equatable>(
        of value: Value,
        perform action: @escaping () -> Void
    ) -> some View {
        onChange(of: value) {
            action()
        }
    }

    /// Kept for the two call sites that watch a count.
    public func onMessageCountChanged(count: Int, action: @escaping () -> Void) -> some View {
        onValueChanged(of: count, perform: action)
    }
}

// MARK: - Translucent window background

/// An `NSVisualEffectView` behind the whole window, for `useTranslucentBackground`.
///
/// That setting was stored and rendered as a switch labelled "Enable macOS vibrancy effect", and
/// nothing read it. Vibrancy needs two halves: a material behind the content, and content that is
/// not painting an opaque colour over it — so `ThemeColors.paneBg(for:translucent:)` thins the
/// sidebar and inspector fills when this is on. The centre pane stays opaque, which is the
/// standard macOS arrangement and keeps chat text readable over whatever is behind the window.
public struct VisualEffectBackground: NSViewRepresentable {
    public let material: NSVisualEffectView.Material

    public init(material: NSVisualEffectView.Material = .sidebar) {
        self.material = material
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.state = .active
    }
}
