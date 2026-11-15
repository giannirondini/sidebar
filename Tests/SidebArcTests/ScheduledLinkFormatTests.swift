import AppKit
import Foundation
import Testing
@testable import SidebArcCore

/// The scheduled-link row's "weekday time" follows the locale's clock, not a
/// fixed 12-hour pattern.
@MainActor
@Suite struct ScheduledLinkFormatTests {
    @Test func usLocaleKeepsTheTwelveHourFormat() {
        // What the fixed "EEE h:mm a" showed, so US users see no change (CLDR puts a
        // narrow no-break space before AM/PM; it looks the same).
        let format = ScheduledLinkRowView.makeDayTimeFormatter(locale: Locale(identifier: "en_US")).dateFormat ?? ""
        #expect(format.replacingOccurrences(of: "\u{202F}", with: " ") == "EEE h:mm a")
    }

    @Test(arguments: ["en_GB", "de_DE", "fr_FR", "it_IT"])
    func twentyFourHourLocalesUseTheirClock(_ identifier: String) {
        let format = ScheduledLinkRowView.makeDayTimeFormatter(locale: Locale(identifier: identifier)).dateFormat ?? ""
        #expect(format.contains("HH"), "\(identifier): \(format)")
        #expect(!format.contains("a"), "\(identifier): \(format)")
    }
}
