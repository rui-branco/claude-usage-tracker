import AppKit
import SwiftUI

/// Manages NSPopover instances for displaying content alongside the MenuBarExtra
/// without disrupting the parent window's lifecycle.
final class PopoverManager {
    static let shared = PopoverManager()

    private var popover: NSPopover?
    private var hostingController: NSHostingController<AnyView>?

    private init() {}

    /// Shows the All Projects popup as an NSPopover anchored to the given view
    /// - Parameters:
    ///   - anchorView: The NSView to anchor the popover to
    ///   - sessions: The sessions to display
    ///   - formatTokens: Token formatting function
    ///   - formatCost: Cost formatting function
    func showAllProjectsPopover(
        anchorView: NSView,
        sessions: [LiveSession],
        formatTokens: @escaping (Int) -> String,
        formatCost: @escaping (Double) -> String
    ) {
        // Close any existing popover first
        closePopover()

        // Create the SwiftUI content with close callback
        let content = AllProjectsPopup(
            sessions: sessions,
            formatTokens: formatTokens,
            formatCost: formatCost,
            onClose: { [weak self] in
                self?.closePopover()
            }
        )

        // Wrap in AnyView for type erasure
        hostingController = NSHostingController(rootView: AnyView(content))

        // Create and configure the popover
        let newPopover = NSPopover()
        newPopover.contentViewController = hostingController
        newPopover.behavior = .transient  // Closes when clicking outside
        newPopover.animates = true

        // Store reference
        popover = newPopover

        // Show to the right of the anchor view
        newPopover.show(
            relativeTo: anchorView.bounds,
            of: anchorView,
            preferredEdge: .maxX  // Right side
        )
    }

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

/// A button that can be used as an anchor for NSPopover
struct PopoverAnchorButton: NSViewRepresentable {
    let title: String
    let count: Int
    let action: (NSView) -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .inline
        button.isBordered = false
        button.contentTintColor = .controlAccentColor

        // Create attributed string with icon
        let attachment = NSTextAttachment()
        attachment.image = NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: nil)

        let attrString = NSMutableAttributedString(string: "Show All (\(count)) ")
        attrString.append(NSAttributedString(attachment: attachment))
        attrString.addAttributes([
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.controlAccentColor
        ], range: NSRange(location: 0, length: attrString.length))

        button.attributedTitle = attrString
        button.target = context.coordinator
        button.action = #selector(Coordinator.buttonClicked(_:))

        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.action = action
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    class Coordinator: NSObject {
        var action: (NSView) -> Void

        init(action: @escaping (NSView) -> Void) {
            self.action = action
        }

        @objc func buttonClicked(_ sender: NSButton) {
            action(sender)
        }
    }
}
