import AppKit
import Testing
@testable import SidebArcCore

@MainActor
@Suite struct InlineEditableTextFieldTests {

    let editableTextField: InlineEditableTextField


    init() {

        editableTextField = InlineEditableTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 30))

    }

    // MARK: - Initialization Tests

    @Test func testInitialState() {
        #expect(!editableTextField.isEditing)
        #expect(!editableTextField.textField.isEditable)
        #expect(!editableTextField.textField.isSelectable)
        #expect(!editableTextField.textField.isBordered)
        #expect(!editableTextField.textField.drawsBackground)
    }

    @Test func testTextFieldIsConfiguredCorrectly() {
        #expect(editableTextField.textField.lineBreakMode == .byTruncatingTail)
        #expect(editableTextField.textField.focusRingType == .none)
    }

    // MARK: - Text Property Tests

    @Test func testTextPropertyGetterAndSetter() {
        editableTextField.text = "Test Title"
        #expect(editableTextField.text == "Test Title")
        #expect(editableTextField.textField.stringValue == "Test Title")
    }

    // MARK: - Font Property Tests

    @Test func testFontPropertyGetterAndSetter() {
        let customFont = NSFont.systemFont(ofSize: 16, weight: .bold)
        editableTextField.font = customFont

        #expect(editableTextField.font == customFont)
        #expect(editableTextField.textField.font == customFont)
    }

    @Test func testFontPropertyDefaultValue() {
        // Should use ThemeConstants.Fonts.bodyRegular as default
        #expect(editableTextField.font.pointSize > 0)
    }

    // MARK: - Text Color Property Tests

    @Test func testTextColorPropertyGetterAndSetter() {
        let customColor = NSColor.red
        editableTextField.textColor = customColor

        #expect(editableTextField.textColor == customColor)
        #expect(editableTextField.textField.textColor == customColor)
    }

    // MARK: - Begin Inline Rename Tests

    @Test func testBeginInlineRenameEntersEditMode() {
        var commitCalled = false
        var cancelCalled = false

        editableTextField.text = "Original Title"
        editableTextField.beginInlineRename(
            onCommit: { _ in commitCalled = true },
            onCancel: { cancelCalled = true }
        )

        #expect(editableTextField.isEditing)
        #expect(!commitCalled)
        #expect(!cancelCalled)
        #expect(editableTextField.textField.isEditable)
        #expect(editableTextField.textField.isSelectable)
    }

    @Test func testBeginInlineRenameIgnoresWhenAlreadyEditing() {
        var firstCommitCalled = false
        var secondCommitCalled = false

        editableTextField.beginInlineRename(
            onCommit: { _ in firstCommitCalled = true },
            onCancel: { }
        )

        // Try to begin again
        editableTextField.beginInlineRename(
            onCommit: { _ in secondCommitCalled = true },
            onCancel: { }
        )

        // Should still be in editing mode from first call
        #expect(editableTextField.isEditing)
        #expect(!firstCommitCalled)
        // Second commit handler should not be set
        #expect(!secondCommitCalled)
    }

    // MARK: - Cancel Inline Rename Tests

    @Test func testCancelInlineRenameRestoresOriginalText() {
        editableTextField.text = "Original Title"

        var cancelCalled = false
        editableTextField.beginInlineRename(
            onCommit: { _ in },
            onCancel: { cancelCalled = true }
        )

        // Modify the text
        editableTextField.textField.stringValue = "Modified Title"

        // Cancel the edit
        editableTextField.cancelInlineRename()

        #expect(editableTextField.text == "Original Title")
        #expect(cancelCalled)
        #expect(!editableTextField.isEditing)
    }

    @Test func testCancelInlineRenameIgnoresWhenNotEditing() {
        // Try to cancel without being in edit mode
        editableTextField.cancelInlineRename()

        // Should not crash and editing state should remain false
        #expect(!editableTextField.isEditing)
    }

    // MARK: - Finish Inline Rename Tests

    @Test func testFinishInlineRenameResetsEditingState() {
        editableTextField.text = "Original"

        var commitCalled = false
        editableTextField.beginInlineRename(
            onCommit: { _ in commitCalled = true },
            onCancel: { }
        )

        // Simulate completion by calling the delegate method manually
        // (In real usage, this would be triggered by Return key)
        editableTextField.textField.stringValue = "New Title"

        // Create a notification to simulate Return key
        let userInfo: [String: Any] = ["NSTextMovement": NSReturnTextMovement]
        let notification = Notification(
            name: NSControl.textDidEndEditingNotification,
            object: editableTextField.textField,
            userInfo: userInfo
        )

        editableTextField.controlTextDidEndEditing(notification)

        #expect(!editableTextField.isEditing)
        #expect(!editableTextField.textField.isEditable)
        #expect(commitCalled)
    }

    @Test func testFinishInlineRenameWithEmptyTextCancels() {
        editableTextField.text = "Original"

        var commitCalled = false
        var cancelCalled = false
        editableTextField.beginInlineRename(
            onCommit: { _ in commitCalled = true },
            onCancel: { cancelCalled = true }
        )

        // Set empty text
        editableTextField.textField.stringValue = "   "

        let userInfo: [String: Any] = ["NSTextMovement": NSReturnTextMovement]
        let notification = Notification(
            name: NSControl.textDidEndEditingNotification,
            object: editableTextField.textField,
            userInfo: userInfo
        )

        editableTextField.controlTextDidEndEditing(notification)

        #expect(!commitCalled)
        #expect(cancelCalled)
        #expect(editableTextField.text == "Original")
    }

    @Test func testFinishInlineRenameWithEscapeCancels() {
        editableTextField.text = "Original"

        var commitCalled = false
        var cancelCalled = false
        editableTextField.beginInlineRename(
            onCommit: { _ in commitCalled = true },
            onCancel: { cancelCalled = true }
        )

        editableTextField.textField.stringValue = "Modified"

        // Simulate Escape key
        let userInfo: [String: Any] = ["NSTextMovement": NSCancelTextMovement]
        let notification = Notification(
            name: NSControl.textDidEndEditingNotification,
            object: editableTextField.textField,
            userInfo: userInfo
        )

        editableTextField.controlTextDidEndEditing(notification)

        #expect(!commitCalled)
        #expect(cancelCalled)
        #expect(editableTextField.text == "Original")
    }

    // MARK: - Whitespace Trimming Tests

    @Test func testFinishInlineRenameTrimsWhitespace() {
        editableTextField.text = "Original"

        var committedValue: String?
        editableTextField.beginInlineRename(
            onCommit: { value in committedValue = value },
            onCancel: { }
        )

        editableTextField.textField.stringValue = "  New Title  "

        let userInfo: [String: Any] = ["NSTextMovement": NSReturnTextMovement]
        let notification = Notification(
            name: NSControl.textDidEndEditingNotification,
            object: editableTextField.textField,
            userInfo: userInfo
        )

        editableTextField.controlTextDidEndEditing(notification)

        #expect(committedValue == "New Title")
        #expect(editableTextField.text == "New Title")
    }
}
