import AppKit
import Testing
@testable import SidebArcCore

/// The Favorites grid adapts its columns to the sidebar width; the cap does not.
/// Grid width = window width − 2 × window padding (8) − 2 × grid inset (2).
@MainActor
@Suite struct PinnedTabsLayoutTests {
    @Test func columnsAtSidebarWidths() {
        #expect(PinnedTabsView.columnCount(forWidth: 260) == 3)  // minimum window, 280
        #expect(PinnedTabsView.columnCount(forWidth: 320) == 3)  // default window, 340
        #expect(PinnedTabsView.columnCount(forWidth: 395) == 3)
        #expect(PinnedTabsView.columnCount(forWidth: 396) == 4)  // window ≈ 416
        #expect(PinnedTabsView.columnCount(forWidth: 500) == 5)  // maximum window, 520
        #expect(PinnedTabsView.columnCount(forWidth: 0) == 3)    // before the first layout
    }

    @Test func rowsGrowToHoldEveryFavorite() {
        #expect(PinnedTabsView.rowCount(tiles: 0, columns: 3) == 0)
        #expect(PinnedTabsView.rowCount(tiles: 9, columns: 3) == 3)
        #expect(PinnedTabsView.rowCount(tiles: Profile.maxFavorites, columns: 3) == 4)
        #expect(PinnedTabsView.rowCount(tiles: Profile.maxFavorites, columns: 5) == 3)
    }

    @Test func capIsIndependentOfTheGrid() {
        #expect(Profile.maxFavorites == 12)
    }
}
