import AppKit

/// The images behind link, note, favorite and space icons: one place for the
/// symbol, favicon and emoji rules that rows and tiles share.
enum IconImages {
    /// An SF Symbol as a template image (tinted by its view), or nil for an unknown name.
    static func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight = .semibold) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight))
        image?.isTemplate = true
        return image
    }

    /// A favicon file as a full-colour image, or nil when it's missing or unreadable.
    static func favicon(atPath path: String) -> NSImage? {
        guard FileManager.default.fileExists(atPath: path),
              let image = NSImage(contentsOfFile: path) else { return nil }
        image.isTemplate = false
        return image
    }
}

extension CustomIcon {
    /// The icon's image, or nil when it can't be drawn: an unknown symbol, or a
    /// favicon file that's gone (callers pick their own placeholder).
    @MainActor
    func image(emojiSize: CGFloat, symbolPointSize: CGFloat, symbolWeight: NSFont.Weight = .semibold) -> NSImage? {
        switch self {
        case .emoji(let emoji):
            return NodeListViewController.imageFromEmoji(emoji, size: emojiSize)
        case .sfSymbol(let name):
            return IconImages.symbol(name, pointSize: symbolPointSize, weight: symbolWeight)
        case .cachedFavicon(let path):
            return IconImages.favicon(atPath: path)
        }
    }
}
