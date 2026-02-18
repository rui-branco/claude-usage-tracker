import AppKit
import SwiftUI

/// Manages NSPopover instances for displaying content alongside the MenuBarExtra
/// without disrupting the parent window's lifecycle.
final class PopoverManager {
    static let shared = PopoverManager()

    private var popover: NSPopover?
    private var hostingController: NSHostingController<AnyView>?

    private init() {}

    /// Closes the current popover without affecting the parent window
    func closePopover() {
        popover?.performClose(nil)
        popover = nil
        hostingController = nil
    }

    /// Returns whether a popover is currently shown
    var isPopoverShown: Bool {
        popover?.isShown ?? false
    }
}
