import AppKit
import Testing
@testable import SidebArcCore

/// An editable NSTextField has no intrinsic width, and the rows bound their title
/// only from above (`trailing ≤ …`), so a row laid out while already renaming gave
/// the field 0 pt. Real, invisible window so Auto Layout runs as in the app.
@MainActor
@Suite struct InlineRenameLayoutTests {
    private let window: NSWindow
    private static let rowWidth: CGFloat = 340
    /// `NodeRowView`'s title-to-edge inset when the delete button is hidden.
    private static let trailingInset: CGFloat = 16

    init() {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.rowWidth, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        // Closed by the tests; ARC owns it.
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.orderFrontRegardless()
    }

    private func makeRow(title: String) throws -> (NodeRowView, InlineEditableTextField) {
        let row = NodeRowView(frame: .zero)
        window.contentView?.addSubview(row)
        row.configure(title: title, icon: nil, titleFont: ThemeConstants.Fonts.bodyRegular,
                      showDelete: true, metrics: ListMetrics(), onDelete: nil, isSelected: false)
        let field = try #require(row.subviews.compactMap { $0 as? InlineEditableTextField }.first)
        return (row, field)
    }

    private func place(_ row: NodeRowView) {
        row.frame = NSRect(x: 0, y: 0, width: Self.rowWidth, height: ListMetrics().rowHeight)
        row.layoutSubtreeIfNeeded()
    }

    @Test func rowLaidOutWhileRenamingFillsTheRow() async throws {
        let (row, field) = try makeRow(title: "A bookmark")
        row.beginInlineRename(onCommit: { _ in }, onCancel: {})
        // beginInlineRename focuses on the next main-loop turn.
        try await Task.sleep(nanoseconds: 50_000_000)
        place(row)

        #expect(!field.hasAmbiguousLayout)
        #expect(field.frame.maxX == Self.rowWidth - Self.trailingInset)
        window.close()
    }

    @Test func titleKeepsItsTextWidthWhenNotEditing() throws {
        let (row, field) = try makeRow(title: "Short")
        place(row)

        #expect(!field.hasAmbiguousLayout)
        #expect(field.frame.width == field.textField.intrinsicContentSize.width)
        #expect(field.frame.maxX < Self.rowWidth - Self.trailingInset)
        window.close()
    }

    @Test func escapeKeyCancelsTheRealFieldEditor() throws {
        let (row, field) = try makeRow(title: "Original")
        place(row)
        var cancelled = false
        row.beginInlineRename(onCommit: { _ in }, onCancel: { cancelled = true })
        window.makeFirstResponder(field.textField)
        let editor = try #require(field.textField.currentEditor())
        editor.string = "Changed"
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                  timestamp: 0, windowNumber: window.windowNumber,
                                                  context: nil, characters: "\u{1b}",
                                                  charactersIgnoringModifiers: "\u{1b}",
                                                  isARepeat: false, keyCode: 53))
        editor.keyDown(with: event)
        #expect(cancelled)
        #expect(!field.isEditing)
        #expect(field.text == "Original")
        window.close()
    }
}
