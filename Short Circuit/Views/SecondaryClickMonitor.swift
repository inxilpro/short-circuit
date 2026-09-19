import AppKit
import SwiftUI

/// SwiftUI builds a row's `contextMenu` content for rows nobody clicked, so selecting from inside
/// that builder makes every row claim the selection in turn. This sees the click itself instead,
/// before the menu opens.
private struct SecondaryClickMonitor: ViewModifier {
    let action: @MainActor () -> Void
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
                    if event.type == .rightMouseDown || event.modifierFlags.contains(.control) {
                        MainActor.assumeIsolated { action() }
                    }
                    return event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}

extension View {
    /// Runs when a right-click or Control-click starts anywhere in the window.
    func onSecondaryClick(perform action: @escaping @MainActor () -> Void) -> some View {
        modifier(SecondaryClickMonitor(action: action))
    }
}
