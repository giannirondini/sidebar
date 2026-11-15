import AppKit
import Foundation
import Testing
@testable import SidebArcCore

/// The shared icon rules every row and tile used to copy: symbols are template
/// images at the requested size, favicons are full colour, and anything that
/// can't be drawn is nil so the caller picks its own placeholder.
@MainActor
@Suite struct IconImagesTests {
    private let scratch = TempDir()

    @Test func symbolsAreTemplatesAtTheRequestedSize() throws {
        let small = try #require(IconImages.symbol("star", pointSize: 16))
        let large = try #require(IconImages.symbol("star", pointSize: 22))
        #expect(small.isTemplate)
        #expect(large.size.height > small.size.height)
        #expect(IconImages.symbol("no.such.symbol.name", pointSize: 16) == nil)
    }

    @Test func faviconsAreFullColourAndMissingOnesAreNil() throws {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let file = scratch.url.appendingPathComponent("icon.png")
        try #require(rep.representation(using: .png, properties: [:])).write(to: file)

        let favicon = try #require(IconImages.favicon(atPath: file.path))
        #expect(!favicon.isTemplate)
        #expect(IconImages.favicon(atPath: scratch.url.appendingPathComponent("gone.ico").path) == nil)

        #expect(CustomIcon.cachedFavicon(file.path).image(emojiSize: 20, symbolPointSize: 16) != nil)
        #expect(CustomIcon.cachedFavicon("/nonexistent/x.ico").image(emojiSize: 20, symbolPointSize: 16) == nil)
    }

    @Test func customIconsUseTheirOwnSizes() throws {
        let emoji = try #require(CustomIcon.emoji("📚").image(emojiSize: 20, symbolPointSize: 16))
        #expect(emoji.size == NSSize(width: 20, height: 20))
        #expect(!emoji.isTemplate)
        let symbol = try #require(CustomIcon.sfSymbol("star").image(emojiSize: 20, symbolPointSize: 16))
        #expect(symbol.isTemplate)
        #expect(CustomIcon.sfSymbol("no.such.symbol.name").image(emojiSize: 20, symbolPointSize: 16) == nil)
        #expect(SpaceIconView.image(for: .sfSymbol("star"), size: 16)?.isTemplate == true)
    }
}
