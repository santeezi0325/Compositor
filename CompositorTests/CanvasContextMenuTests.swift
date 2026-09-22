import AppKit
import Testing
@testable import Compositor

/// Right-clicking the canvas did nothing at all before this menu existed. The one thing that must not
/// regress while fixing that is the brush tools' right-drag, which owns the same button.
@MainActor
@Suite(.serialized)
struct CanvasContextMenuTests {
    private func sessionWithPixels() throws -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 40, height: 20)
        let context = try BrushRaster.context(width: 40, height: 20, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Red"))
        return session
    }
    private func items(_ session: EditorSession) -> [CanvasContextMenu.Item] {
        CanvasContextMenu.groups(for: session).flatMap { $0 }
    }
    private func item(_ title: String, _ session: EditorSession) throws -> CanvasContextMenu.Item {
        try #require(items(session).first { $0.title == title }, "no item titled \(title)")
    }
    private func rightClick(in window: NSWindow, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 20, y: 10), modifierFlags: flags,
                           timestamp: 0, windowNumber: window.windowNumber, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 0)!
    }
    private func canvas(_ session: EditorSession) -> (CanvasView, NSWindow) {
        let view = CanvasView(session: session)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 40, height: 20), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view
        return (view, window)
    }

    /// The whole reason the brush tools are excluded: a right-drag there sets size and hardness, and a
    /// menu popping up would take that away from the tools that use the button most.
    @Test func brushToolsKeepTheRightButtonForThemselves() throws {
        let session = try sessionWithPixels()
        for tool in NavigationTool.allCases where tool.isBrushTool {
            session.selectTool(tool)
            #expect(!CanvasContextMenu.isAvailable(session, spaceHeld: false),
                    "\(tool): a menu here would steal the brush resize drag")
        }
        // And the tools that were doing nothing with the button do get one.
        for tool in [NavigationTool.move, .marquee, .lasso, .wand] {
            session.selectTool(tool)
            #expect(CanvasContextMenu.isAvailable(session, spaceHeld: false), "\(tool): still no menu")
        }
    }

    @Test func noMenuWithoutADocumentOrWhileSpaceIsPanning() throws {
        let empty = EditorSession()
        empty.selectTool(.move)
        #expect(!CanvasContextMenu.isAvailable(empty, spaceHeld: false), "a menu with no document to act on")

        let session = try sessionWithPixels()
        session.selectTool(.move)
        #expect(CanvasContextMenu.isAvailable(session, spaceHeld: false))
        #expect(!CanvasContextMenu.isAvailable(session, spaceHeld: true), "Space is panning, not opening a menu")
    }

    /// The view has to agree with `isAvailable`, since the view is the half the user actually meets.
    @Test func theCanvasViewReturnsTheMenuOnlyWhenItShould() throws {
        let session = try sessionWithPixels()
        let (view, window) = canvas(session)
        let event = rightClick(in: window)

        session.selectTool(.brush)
        #expect(view.menu(for: event) == nil, "the brush tool was handed a menu")

        session.selectTool(.marquee)
        let menu = try #require(view.menu(for: event), "the marquee tool got no menu")
        #expect(menu.items.contains { $0.title == "Deselect" })
        // Left on, AppKit would validate each item against the responder chain, which answers yes to
        // the shared selector, and every item would come up enabled whatever the session says.
        #expect(!menu.autoenablesItems)
    }

    /// Control-click is AppKit's other route to a context menu, and on this canvas Control already means
    /// "drag without snapping" (EditorCanvas: "Control drags freely", which TransformPressTests relies on).
    /// The menu has to stay off that gesture or the press that starts such a drag never arrives.
    @Test func controlClickIsLeftToTheFreeDrag() throws {
        let session = try sessionWithPixels()
        session.selectTool(.move)
        let (view, window) = canvas(session)
        #expect(view.menu(for: rightClick(in: window)) != nil, "an ordinary right-click got no menu")
        #expect(view.menu(for: rightClick(in: window, flags: .control)) == nil,
                "Control-click opened the menu and would swallow the free drag")
    }

    /// `canEditLayers` already contains `textDraft == nil`, so with the inline editor up every gated
    /// item is gray and the menu is Fit Canvas and Actual Pixels — offered over a text field, where the
    /// useful menu is the text view's own. Refusing hands the click back so that one can appear.
    @Test func noMenuWhileTextIsBeingEdited() throws {
        let session = EditorSession()
        session.createDocument(width: 800, height: 600, emptyLayer: true)
        session.selectTool(.type)
        #expect(CanvasContextMenu.isAvailable(session, spaceHeld: false))
        session.beginText(at: CGPoint(x: 30, y: 40))
        #expect(session.textDraft != nil, "the draft never opened, so this proves nothing")
        #expect(!CanvasContextMenu.isAvailable(session, spaceHeld: false),
                "a menu of gray items offered over the text being edited")
    }

    /// Transform names what it will act on, the way the Layer menu does: Cmd-T takes the selected
    /// pixels when there is a selection and the layer when there is not.
    @Test func transformNamesItsTargetAndTakesBothGuards() throws {
        let session = try sessionWithPixels()
        session.selectTool(.marquee)
        #expect(session.selection == nil)
        let layer = try item("Transform Layer", session)
        #expect(layer.isEnabled == (session.canTransform || session.canTransformSelection))
        #expect(session.canTransform, "a pixel layer should be transformable")

        session.selectAll()
        #expect(session.canTransformSelection)
        _ = try item("Transform Selection", session)
        #expect(items(session).allSatisfy { $0.title != "Transform Layer" }, "both titles at once")
    }

    /// The titles are not written out twice: the built menu is checked against the items it came from,
    /// so an item added later cannot quietly fail to reach the menu.
    @Test func theBuiltMenuMatchesTheItemsAndSeparatesTheGroups() throws {
        let session = try sessionWithPixels()
        session.selectTool(.marquee)
        let menu = CanvasContextMenu.make(for: session)
        let groupCount = CanvasContextMenu.groups(for: session).count

        #expect(menu.items.filter(\.isSeparatorItem).count == groupCount - 1)
        #expect(menu.items.filter { !$0.isSeparatorItem }.map(\.title) == items(session).map(\.title))
        for entry in menu.items where !entry.isSeparatorItem {
            #expect(entry.target != nil, "\(entry.title) has no target, so choosing it would do nothing")
            // NSMenuItem holds its target weakly; without representedObject the box dies before the click.
            #expect(entry.representedObject != nil, "\(entry.title)'s target has nothing retaining it")
        }
    }

    /// The items borrow the session's own guards, so they have to move when the session's state moves.
    @Test func selectionItemsFollowWhetherThereIsASelection() throws {
        let session = try sessionWithPixels()
        session.selectTool(.marquee)
        #expect(session.selection == nil)
        let before = try ["Deselect", "Inverse", "Clear Selection Pixels"].map { try item($0, session) }
        for entry in before { #expect(!entry.isEnabled, "\(entry.title) was offered with nothing selected") }

        session.selectAll()
        #expect(session.selection != nil)
        let after = try ["Deselect", "Inverse"].map { try item($0, session) }
        for entry in after { #expect(entry.isEnabled, "\(entry.title) stayed gray with a selection") }
    }

    /// Choosing an item has to run the command, not merely look enabled. Both routes are exercised:
    /// the item's own closure, and the NSMenuItem the menu was built from.
    @Test func choosingAnItemReachesTheSession() throws {
        let session = try sessionWithPixels()
        session.selectTool(.marquee)
        #expect(session.selection == nil)
        try item("Select All", session).run()
        #expect(session.selection != nil, "Select All did not reach the session")

        try item("Deselect", session).run()
        #expect(session.selection == nil, "Deselect did not reach the session")

        let menu = CanvasContextMenu.make(for: session)
        let entry = try #require(menu.items.first { $0.title == "Select All" })
        let target = try #require(entry.target as? NSObject)
        let action = try #require(entry.action)
        _ = target.perform(action)
        #expect(session.selection != nil, "the built menu item did not reach the session")
    }
}
