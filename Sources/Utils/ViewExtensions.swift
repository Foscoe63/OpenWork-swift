import SwiftUI

extension View {
    @ViewBuilder
    public func onMessageCountChanged(count: Int, action: @escaping () -> Void) -> some View {
        if #available(macOS 14.0, *) {
            self.onChange(of: count) {
                action()
            }
        } else {
            self.onChange(of: count) { _ in
                action()
            }
        }
    }
}
