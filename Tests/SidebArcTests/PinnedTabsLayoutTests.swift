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
        #expect(PinnedTabsView.columnCount(forWidth: 391) == 3)
        #expect(PinnedTabsView.columnCount(forWidth: 392) == 4)  // window ≈ 412
        #expect(PinnedTabsView.columnCount(forWidth: 491) == 4)
        #expect(PinnedTabsView.columnCount(forWidth: 492) == 5)  // window ≈ 512
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

    /// A space switch to another profile swaps the grid early only when it keeps its height.
    @Test func sameHeightMeansSameRowCount() {
        #expect(PinnedTabsView.hasSameHeight(tiles: 1, tiles: 3, width: 320))    // 1 row each
        #expect(PinnedTabsView.hasSameHeight(tiles: 4, tiles: 6, width: 320))    // 2 rows each
        #expect(!PinnedTabsView.hasSameHeight(tiles: 3, tiles: 4, width: 320))   // 1 vs 2 rows
        #expect(PinnedTabsView.hasSameHeight(tiles: 3, tiles: 4, width: 400))    // 4 columns: 1 row each
        #expect(!PinnedTabsView.hasSameHeight(tiles: 0, tiles: 1, width: 320))   // hidden vs 1 row
        #expect(PinnedTabsView.hasSameHeight(tiles: 0, tiles: 0, width: 320))
    }
}
