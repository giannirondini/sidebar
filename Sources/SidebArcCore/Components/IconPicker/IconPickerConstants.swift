import Foundation

struct IconPickerConstants {

    /// Emoji offered in the icon picker, by category (Emoji 14 or older, so all of
    /// them render on macOS 13). Searchable by their Unicode names (`emojiSearch`).
    static let emojis: [String] = [
        // Smileys & emotion
        "😀", "😃", "😄", "😁", "😆", "😅", "😂", "🤣", "🥲", "🥹",
        "😊", "😇", "🙂", "🙃", "😉", "😌", "😍", "🥰", "😘", "😋",
        "😛", "😜", "🤪", "🤓", "😎", "🥸", "🤩", "🥳", "😏", "😒",
        "😔", "😢", "🥺", "😴", "🤔", "🤫", "🤭", "🤗", "😤", "😡", "🤯",
        "😱", "🥶", "🥵", "🤢", "🤠", "😈", "👻", "💀", "🤖", "👽",
        "💩", "🙈",
        // People & gestures
        "👋", "🤚", "✋", "👌", "🤌", "✌️", "🤞", "🤟", "🤘", "🤙",
        "👈", "👉", "👆", "👇", "☝️", "👍", "👎", "✊", "👊", "👏",
        "🙌", "🤝", "🙏", "✍️", "💪", "🧠", "👀", "🧑‍💻", "🧑‍🎨", "🧑‍🔬",
        "🧑‍🏫", "🧑‍🍳", "🧑‍🚀", "🧑‍💼", "👶", "👪", "🗣️",
        // Hearts & feelings
        "❤️", "🧡", "💛", "💚", "💙", "💜", "🤎", "🖤", "🤍", "💔",
        "❣️", "💕", "💞", "💓", "💗", "💖", "💘", "💝", "💯", "💢",
        "💥", "💬", "💭", "💤",
        // Animals
        "🐶", "🐱", "🐭", "🐹", "🐰", "🦊", "🐻", "🐼", "🐨", "🐯",
        "🦁", "🐮", "🐷", "🐸", "🐵", "🐔", "🐧", "🐦", "🐤", "🦆",
        "🦅", "🦉", "🦇", "🐺", "🐴", "🦄", "🐝", "🐛", "🦋", "🐌",
        "🐞", "🐢", "🐍", "🦖", "🐙", "🦑", "🦀", "🐠", "🐬", "🐳",
        "🦈", "🐘", "🦒", "🦘", "🦔",
        // Nature & weather
        "🌵", "🌲", "🌳", "🌴", "🌱", "🌿", "☘️", "🍀", "🍁", "🍂",
        "🍄", "🌾", "🌷", "🌹", "🌺", "🌸", "🌼", "🌻", "🌞", "🌝",
        "🌙", "⚡", "🔥", "🌈", "☀️", "⛅", "☁️", "🌧️", "⛈️", "❄️",
        "☃️", "🌊", "💧", "🌍", "🌋",
        // Food & drink
        "🍎", "🍐", "🍊", "🍋", "🍌", "🍉", "🍇", "🍓", "🫐", "🍒",
        "🍑", "🥭", "🍍", "🥥", "🥝", "🍅", "🥑", "🥦", "🥕", "🌽",
        "🌶️", "🥐", "🥖", "🥨", "🧀", "🥚", "🍳", "🥞", "🥓", "🍔",
        "🍟", "🍕", "🌭", "🌮", "🌯", "🥗", "🍝", "🍜", "🍣", "🍱",
        "🍦", "🍰", "🎂", "🍩", "🍪", "🍫", "🍿", "🍴", "☕", "🍵", "🧋",
        "🥤", "🍺", "🍷", "🥂", "🍸",
        // Activities
        "⚽", "🏀", "🏈", "⚾", "🎾", "🏐", "🏉", "🎱", "🏓", "🏸",
        "🥊", "⛳", "🏹", "🎣", "🤿", "🎿", "🏂", "🏄", "🏊", "🚴",
        "🧗", "🧘", "🎮", "🕹️", "🎲", "🧩", "♟️", "🎯", "🎳", "🎨",
        "🎭", "🎬", "🎤", "🎧", "🎵", "🎶", "🎸", "🎹", "🥁", "🎷",
        "🎺", "🎻",
        // Travel & places
        "🚗", "🚕", "🚌", "🏎️", "🚓", "🚑", "🚒", "🚚", "🚜", "🛵",
        "🏍️", "🚲", "🛴", "🚂", "🚆", "🚇", "✈️", "🚁", "🚀", "🛸",
        "⛵", "🚤", "🛳️", "⚓", "🗺️", "🧭", "🏔️", "⛰️", "🏕️", "🏖️",
        "🏝️", "🏜️", "🏙️", "🌆", "🌉", "🗽", "🗼", "🏰", "🏠", "🏡",
        "🏢", "🏫", "🏥", "🏦", "🏨",
        // Objects & work
        "💡", "🔦", "🕯️", "📱", "💻", "🖥️", "⌨️", "🖱️", "🖨️", "💾",
        "💿", "📷", "🎥", "📺", "📻", "⏰", "⌛", "⏱️", "📡", "🔋",
        "🔌", "💰", "💳", "💎", "⚖️", "🔧", "🔨", "🛠️", "⚙️", "🧲",
        "🧪", "🔬", "🔭", "💊", "🩺", "🧬", "🔑", "🗝️", "🔒", "🔓",
        "🛒", "🎁", "🎈", "🎀", "🪄", "📦", "📫", "✉️", "📧", "📝",
        "📄", "📊", "📈", "📉", "🗂️", "📁", "📂", "🗃️", "🗄️", "🗒️", "🗓️", "💼", "🎓",
        "📅", "📋", "📌", "📍", "📎", "📏", "📐", "✂️", "🖊️", "✏️",
        "🖍️", "🔍", "📚", "📖", "📓", "📕", "📗", "📘", "📙", "🔖",
        "🏷️", "🧾", "🔔", "📣", "🧹", "🧸",
        // Symbols & flags
        "⭐", "🌟", "✨", "💫", "🏆", "🥇", "🏅", "🎖️", "🎉", "🎊",
        "🏁", "🚩", "🏳️", "🏴", "🏳️‍🌈", "🔮", "🧿", "♻️", "⚠️", "🚫",
        "⛔", "✅", "❌", "❓", "❗", "➕", "🔴", "🟠", "🟡", "🟢",
        "🔵", "🟣", "🟤", "⚫", "⚪", "🔶", "🔷", "🔺", "⭕", "♾️",
        "⚛️", "☮️", "☯️", "🆕", "🆗", "🆒", "🆘", "🔝", "🇮🇹", "🇪🇺",
        "🇬🇧", "🇺🇸", "🇩🇪", "🇫🇷", "🇪🇸", "🇨🇭", "🇯🇵",
    ]

    /// Search text of each emoji: the lowercased Unicode names of its characters
    /// ("rocket", "heavy black heart"…, without joiners, variation selectors and
    /// skin-tone modifiers) plus `emojiKeywords`.
    static let emojiNames: [String: String] = Dictionary(uniqueKeysWithValues: emojis.map {
        ($0, [searchName(of: $0), emojiKeywords[$0]].compactMap { $0 }.joined(separator: " "))
    })

    /// Everyday words the Unicode names lack (❤️ is "heavy black heart", 💻 "personal
    /// computer"…). Only for gaps; most emoji are found by their names.
    static let emojiKeywords: [String: String] = [
        "❤️": "red love", "🧡": "love", "💛": "love", "💚": "love", "💙": "love", "💜": "love",
        "💻": "laptop mac", "🖥️": "desktop monitor", "📱": "phone iphone", "⌨️": "type",
        "😂": "laugh lol", "🤣": "laugh lol", "😊": "happy", "😀": "happy", "😢": "sad", "😔": "sad",
        "👍": "like yes ok", "👎": "dislike no", "🙏": "thanks please", "👋": "hello bye hi",
        "✅": "done check yes", "❌": "no cancel", "⚠️": "alert", "💡": "idea", "🔒": "secure private",
        "🏠": "home", "🏢": "work office", "💼": "work job", "📚": "study read", "🎓": "study school",
        "💰": "money finance", "💳": "money pay card", "🛒": "shop shopping", "🍴": "food",
        "☕": "coffee", "🍵": "tea", "🎮": "game games", "🎵": "music", "🎧": "music", "🎬": "movie film",
        "📷": "photo", "✈️": "travel flight", "🚗": "car drive", "🧠": "brain think",
        "🔥": "hot", "⭐": "favorite", "🌟": "favorite", "📌": "pin", "📅": "calendar date", "🗓️": "calendar",
    ]

    /// Emoji whose names contain every word of `query` (case-insensitive), in list
    /// order; all of them for an empty query.
    static func emojiSearch(_ query: String) -> [String] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return emojis }
        return emojis.filter { emoji in
            let name = emojiNames[emoji] ?? ""
            return words.allSatisfy { name.contains($0) }
        }
    }

    private static func searchName(of emoji: String) -> String {
        // A flag is two regional indicators ("regional indicator symbol letter i …"):
        // search it by "flag" and the English country name instead.
        let scalars = Array(emoji.unicodeScalars)
        if scalars.count == 2, scalars.allSatisfy({ (0x1F1E6...0x1F1FF).contains($0.value) }) {
            let code = String(scalars.compactMap { UnicodeScalar($0.value - 0x1F1E6 + 0x41).map(Character.init) })
            let country = Locale(identifier: "en_US").localizedString(forRegionCode: code) ?? ""
            return "flag \(country.lowercased()) \(code.lowercased())"
        }
        return emoji.unicodeScalars
            .filter { !$0.properties.isVariationSelector && !$0.properties.isEmojiModifier && $0.value != 0x200D }
            .compactMap { $0.properties.name?.lowercased() }
            .joined(separator: " ")
    }

    static let sfSymbols: [String] = [
        // Communication
        "envelope.fill", "paperplane.fill", "bubble.left.fill", "phone.fill",
        "video.fill", "mic.fill", "speaker.wave.2.fill", "bell.fill",
        // Media
        "play.fill", "pause.fill", "star.fill", "heart.fill",
        "bookmark.fill", "tag.fill", "camera.fill", "photo.fill",
        // Files & Folders
        "doc.fill", "doc.text.fill", "folder.fill", "archivebox.fill",
        "tray.fill", "externaldrive.fill", "note.text", "list.bullet",
        // Tools
        "wrench.fill", "hammer.fill", "paintbrush.fill", "scissors",
        "pencil", "eraser.fill", "magnifyingglass", "slider.horizontal.3",
        // Objects
        "lightbulb.fill", "key.fill", "lock.fill", "pin.fill",
        "mappin.and.ellipse", "gift.fill", "cart.fill", "creditcard.fill",
        // People & Body
        "person.fill", "person.2.fill", "person.3.fill", "hand.thumbsup.fill",
        "hand.raised.fill", "eye.fill", "brain.head.profile", "figure.walk",
        // Nature & Science
        "leaf.fill", "flame.fill", "drop.fill", "snowflake",
        "cloud.fill", "sun.max.fill", "moon.fill", "sparkles",
        // Tech & Devices
        "desktopcomputer", "laptopcomputer", "iphone", "gamecontroller.fill",
        "keyboard", "printer.fill", "wifi", "antenna.radiowaves.left.and.right",
        // Shapes & Symbols
        "circle.fill", "square.fill", "triangle.fill", "diamond.fill",
        "hexagon.fill", "shield.fill", "flag.fill", "rosette",
        // Arrows & Actions
        "arrow.right", "arrow.up.right", "bolt.fill", "power",
        "checkmark.circle.fill", "xmark.circle.fill", "plus.circle.fill", "minus.circle.fill",
        // Transportation
        "car.fill", "airplane", "bus.fill", "bicycle",
        // Charts & Data
        "chart.bar.fill", "chart.pie.fill", "chart.line.uptrend.xyaxis", "gauge.medium",
    ]
}
