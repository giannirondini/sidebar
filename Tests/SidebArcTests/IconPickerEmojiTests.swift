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
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            grid.setItems(IconPickerConstants.emojis.map { .emoji($0) }) { _ in }
            grid.layoutSubtreeIfNeeded()
        }
        // Not a benchmark: a monotonic clock and a bound far above the usual time
        // (tens of ms; tests run in parallel on loaded CI Macs) that still catches a
        // change making the picker orders of magnitude slower to open.
        #expect(elapsed < .seconds(5))
    }

    /// The popover's grid (280 − 2 × 8 = 264 pt) used to force 8 columns of 34 pt,
    /// which put the 8th column at x = 266: clipped, so every 8th icon was unclickable.
    @Test func gridColumnsFitInsideTheWidth() {
        let popoverGrid = IconPickerGridView.metrics(forWidth: 264)
        #expect(popoverGrid.columns == 7)
        #expect(popoverGrid.cellSize == 34)

        for width in stride(from: CGFloat(34), through: 600, by: 1) {
            let (columns, cellSize) = IconPickerGridView.metrics(forWidth: width)
            let used = CGFloat(columns) * cellSize + CGFloat(columns - 1) * 4
            #expect(used <= width, "width \(width): \(columns) × \(cellSize) needs \(used)")
            #expect(cellSize >= 34)
        }
    }
}
