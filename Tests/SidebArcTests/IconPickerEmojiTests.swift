import AppKit
import Testing
@testable import SidebArcCore

/// The icon picker's emoji list and its search (Unicode names).
@MainActor
@Suite struct IconPickerEmojiTests {
    @Test func emojiAreUniqueSingleCharactersThatRenderAsEmoji() {
        let emojis = IconPickerConstants.emojis
        #expect(emojis.count >= 400)
        #expect(Set(emojis).count == emojis.count)
        for emoji in emojis {
            #expect(emoji.count == 1, "\(emoji) is not one character")
            let scalars = Array(emoji.unicodeScalars)
            // Text-default characters (☀, ✈, ❤ …) need U+FE0F to render as emoji.
            let rendersAsEmoji = scalars.count > 1 || scalars[0].properties.isEmojiPresentation
            #expect(rendersAsEmoji, "\(emoji) (U+\(String(scalars[0].value, radix: 16, uppercase: true))) needs U+FE0F")
        }
    }

    @Test func keywordsOnlyNameListedEmoji() {
        let listed = Set(IconPickerConstants.emojis)
        for emoji in IconPickerConstants.emojiKeywords.keys {
            #expect(listed.contains(emoji), "\(emoji) has keywords but isn't in the list")
        }
    }

    @Test func everyEmojiHasASearchName() {
        for emoji in IconPickerConstants.emojis {
            #expect(!(IconPickerConstants.emojiNames[emoji] ?? "").isEmpty, "\(emoji) has no name")
        }
    }

    @Test func searchMatchesUnicodeNamesAndEveryWord() {
        #expect(IconPickerConstants.emojiSearch("rocket").contains("🚀"))
        #expect(IconPickerConstants.emojiSearch("Red Heart").contains("❤️"))
        #expect(IconPickerConstants.emojiSearch("laptop").contains("💻"))
        #expect(IconPickerConstants.emojiSearch("computer").contains("🧑‍💻"))
        #expect(IconPickerConstants.emojiSearch("flag italy") == ["🇮🇹"])
        #expect(IconPickerConstants.emojiSearch("zzzzz").isEmpty)
        #expect(IconPickerConstants.emojiSearch("  ") == IconPickerConstants.emojis)
    }

    @Test func gridBuildsTheWholeListQuickly() {
        let grid = IconPickerGridView(frame: NSRect(x: 0, y: 0, width: 264, height: 260))
        let start = Date()
        grid.setItems(IconPickerConstants.emojis.map { .emoji($0) }) { _ in }
        grid.layoutSubtreeIfNeeded()
        // Not a benchmark: a generous bound (tests run in parallel) that still catches
        // a list or grid change making the picker an order of magnitude slower to open.
        #expect(Date().timeIntervalSince(start) < 2)
    }
}
