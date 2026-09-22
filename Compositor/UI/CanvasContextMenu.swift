import AppKit

/// The canvas's right-click menu.
///
/// Right-clicking the image did nothing at all before this. The brush tools claim the right button for
/// the size-and-hardness drag (see `CanvasView.rightMouseDown`), and with every other tool the click
/// fell through to a view that had no menu attached, so nothing happened. The layer rows in the Layers
/// panel have had a context menu since the first commit; the canvas never did.
///
/// Every item here calls something the menu bar already calls, with the same guard the menu bar uses.
/// A right-click can therefore do nothing that the menus could not already do, which is the point: this
/// is a shorter route to existing commands, not a new place for behavior to live.
@MainActor
enum CanvasContextMenu {
    /// One item, kept as a plain value so a test can read what the menu offers without opening one.
    struct Item {
        let title: String
        let isEnabled: Bool
        let run: () -> Void
    }

    /// Whether a right-click belongs to the menu at all.
    ///
    /// The brush tools already own the right button, so they never get a menu — taking that drag away
    /// to show a list would be a straight loss for the tool it matters most to. A click mid-stroke or
    /// while Space is panning is not a menu either: the guard mirrors the one in `rightMouseDown` so
    /// the two cannot disagree about who the click belongs to.
    ///
    /// Text being edited is refused for a different reason. `canEditLayers` already contains
    /// `textDraft == nil`, so with the inline editor up every gated item below is gray and the menu
    /// is nothing but Fit Canvas and Actual Pixels. The canvas gives up first responder for the same
    /// reason while a draft is open (see `synchronizeDisplay`), so the click belongs to the text.
    static func isAvailable(_ session: EditorSession, spaceHeld: Bool) -> Bool {
        session.document != nil && !session.tool.isBrushTool && session.textDraft == nil
            && session.brushStroke == nil && session.warpStroke == nil && !spaceHeld
    }

    /// The menu's items, in the groups a separator divides.
    static func groups(for session: EditorSession) -> [[Item]] {
        // Cut and Copy need pixels to take; the menu bar checks these when chosen rather than through
        // `.disabled` because it also has to share the keys with text fields. Here the canvas is
        // definitionally the target, so the same conditions can simply gray the item out.
        let pasteboard = [
            Item(title: "Cut", isEnabled: session.selection != nil && session.canCopyPixels) {
                Task { await session.cutSelection() }
            },
            Item(title: "Copy", isEnabled: session.canCopyPixels) { session.copySelection() },
            Item(title: "Copy Merged", isEnabled: session.canCopyMerged) { session.copyMergedSelection() },
            Item(title: "Paste", isEnabled: session.canPaste) { session.paste() }
        ]
        let selection = [
            Item(title: "Select All", isEnabled: session.canEditSelection) { session.selectAll() },
            Item(title: "Deselect", isEnabled: session.selection != nil && session.canEditSelection) { session.deselect() },
            Item(title: "Inverse", isEnabled: session.selection != nil && session.canEditSelection) { session.invertSelection() },
            Item(title: "Select Layer's Pixels", isEnabled: session.activeLayer?.asset != nil && session.canEditSelection) {
                if let id = session.activeLayerID { session.loadLayerSelection(layerID: id) }
            }
        ]
        // Transform leads this group because it is the most canvas-centric command the app has: the
        // handles it puts up are on the image itself. It names what it will act on the way the Layer
        // menu does, and takes both guards, since Cmd-T transforms the selected pixels when there is
        // a selection and the layer when there is not.
        let pixels = [
            Item(title: session.canTransformSelection ? "Transform Selection" : "Transform Layer",
                 isEnabled: session.canTransform || session.canTransformSelection) {
                session.transformCommand()
            },
            Item(title: "Fill with Foreground Color", isEnabled: session.canEditPixels) {
                Task { await session.fillSelection(with: .foreground) }
            },
            Item(title: "Fill with Background Color", isEnabled: session.canEditPixels) {
                Task { await session.fillSelection(with: .background) }
            },
            Item(title: "Clear Selection Pixels", isEnabled: session.selection != nil && session.canEditPixels) {
                Task { await session.clearSelectedPixels() }
            },
            Item(title: "Content-Aware Fill…", isEnabled: session.canContentAwareFill) {
                session.beginFilter(.contentAwareFill)
            }
        ]
        // Zoom is here because the pointer is already where the user wants to look; `isAvailable` has
        // established there is a document, so neither of these can be reached without one.
        let view = [
            Item(title: "Fit Canvas", isEnabled: true) { session.fit() },
            Item(title: "Actual Pixels", isEnabled: true) { session.zoom(to: 1) }
        ]
        return [pasteboard, selection, pixels, view]
    }

    static func make(for session: EditorSession) -> NSMenu {
        let menu = NSMenu()
        // The items carry their own enabled state, worked out from the session above. Left to itself
        // AppKit would recompute it by asking the responder chain whether anything handles `fire`,
        // which is always yes, so every item would come up enabled.
        menu.autoenablesItems = false
        for (index, group) in groups(for: session).enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for item in group {
                let entry = NSMenuItem(title: item.title, action: #selector(ActionBox.fire), keyEquivalent: "")
                let box = ActionBox(item.run)
                entry.target = box
                // `NSMenuItem.target` is weak, so the box needs an owner or it dies before the click.
                entry.representedObject = box
                entry.isEnabled = item.isEnabled
                menu.addItem(entry)
            }
        }
        return menu
    }
}

/// Target/action wants a selector on an object, and these items are closures over the session.
@MainActor
private final class ActionBox: NSObject {
    private let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}
