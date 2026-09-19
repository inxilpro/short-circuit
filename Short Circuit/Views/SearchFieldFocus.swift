import AppKit

/// SwiftUI won't move focus from the results to the toolbar's search field while the results hold
/// it, so ⌘F asks AppKit. `.searchable` puts an `NSSearchToolbarItem` in the toolbar, and that
/// item knows how to start a search; the view hunt is a fallback for a collapsed toolbar.
enum SearchFieldFocus {
    @discardableResult
    static func claim() -> Bool {
        let windows = [NSApp.keyWindow].compactMap { $0 } + NSApp.windows.filter(\.isVisible)
        for window in windows {
            if let item = window.toolbar?.items.lazy.compactMap({ $0 as? NSSearchToolbarItem }).first {
                item.beginSearchInteraction()
                return true
            }
            guard let root = window.contentView?.superview ?? window.contentView,
                  let field = searchField(in: root)
            else { continue }
            if window.makeFirstResponder(field) { return true }
        }
        return false
    }

    /// The field is SwiftUI's own `AppKitSearchField`, not an `NSSearchField`; its accessory
    /// buttons share the name, so only a view that can take focus counts.
    /// True while a text field (the search field's editor, say) has the keyboard.
    static var isEditingText: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.isFieldEditor == true
    }

    private static func searchField(in view: NSView) -> NSView? {
        let name = String(describing: type(of: view))
        if name.localizedCaseInsensitiveContains("searchfield"), !name.localizedCaseInsensitiveContains("accessory"), view.acceptsFirstResponder {
            return view
        }
        for subview in view.subviews {
            if let field = searchField(in: subview) { return field }
        }
        return nil
    }
}
