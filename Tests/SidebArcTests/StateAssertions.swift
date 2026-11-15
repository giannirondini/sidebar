import Foundation
import Testing
@testable import SidebArcCore

/// Node equality is identity-only, so compare tree contents separately.
func deeplyEqual(_ lhs: AppState, _ rhs: AppState) -> Bool {
    func nodesEqual(_ lhs: [Node], _ rhs: [Node]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            switch (left, right) {
            case (.link(let a), .link(let b)):
                return a == b
            case (.note(let a), .note(let b)):
                return a == b
            case (.folder(var a), .folder(var b)):
                let childrenMatch = nodesEqual(a.children, b.children)
                a.children = []
                b.children = []
                return a == b && childrenMatch
            default:
                return false
            }
        }
    }

    guard lhs.workspaces.count == rhs.workspaces.count else { return false }
    let treesMatch = zip(lhs.workspaces, rhs.workspaces).allSatisfy { nodesEqual($0.items, $1.items) }
    var left = lhs
    var right = rhs
    for index in left.workspaces.indices {
        left.workspaces[index].items = []
        right.workspaces[index].items = []
    }
    return treesMatch && left == right
}

func expectPersisted(_ model: AppModel, in store: DataStore, sourceLocation: SourceLocation = #_sourceLocation) {
    if !deeplyEqual(model.state, store.load()) {
        Issue.record("Saved state differs from the in-memory state", sourceLocation: sourceLocation)
    }
    let reloaded = AppModel(store: store)
    if !deeplyEqual(model.state, reloaded.state) {
        Issue.record("Reloaded state differs from the in-memory state", sourceLocation: sourceLocation)
    }
}
