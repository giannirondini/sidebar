import AppKit
import Testing
@testable import SidebArcCore

@MainActor
@Suite(.serialized) struct NodeListRenameTests {
    @Test(arguments: [false, true])
    func refreshPreservesAnActiveRenameAndCancellationDoesNotSwallowTheNextSelection(additionalRow: Bool) async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        defer { window.close() }
        let controller = NodeListViewController()
        window.contentViewController = controller
        controller.view.frame = NSRect(x: 0, y: 0, width: 340, height: 300)
        window.orderFrontRegardless()
        let link = Link(id: UUID(), title: "Original", url: "https://example.com", faviconPath: nil,
                        customIcon: .sfSymbol("star"))
        let other = Link(id: UUID(), title: "Other", url: "https://example.org", faviconPath: nil,
                         customIcon: .sfSymbol("star"))
        let nodes: [Node] = [.link(link)] + (additionalRow ? [.link(other)] : [])
        controller.findNodeById = { $0 == link.id ? .link(link) : nil }
        controller.reloadData(with: nodes, forceExpand: false, animated: false)
        controller.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let collection = try #require(controller.scrollView.documentView as? NSCollectionView)
        let indexPath = IndexPath(item: 0, section: 0)
        let item = try #require(collection.item(at: indexPath) as? NodeCollectionViewItem)
        let field = try #require(item.view.subviews.compactMap { $0 as? InlineEditableTextField }.first)
        controller.beginInlineRename(nodeId: link.id, indexPath: indexPath)
        window.makeFirstResponder(field.textField)
        let editor = try #require(field.textField.currentEditor())
        editor.string = "In progress"
        var updated = link
        updated.faviconPath = "/tmp/new-icon.ico"
        controller.reloadData(with: [.link(updated)] + (additionalRow ? [.link(other)] : []), forceExpand: false)
        #expect(collection.item(at: indexPath) === item)
        #expect(field.isEditing)
        #expect(editor.string == "In progress")

        controller.cancelInlineRename()
        try await Task.sleep(nanoseconds: 50_000_000)
        var selected = false
        controller.onNodeSelected = { selected = $0 == link.id }
        collection.selectItems(at: [indexPath], scrollPosition: [])
        controller.collectionView(collection, didSelectItemsAt: [indexPath])
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(selected)
    }
}
