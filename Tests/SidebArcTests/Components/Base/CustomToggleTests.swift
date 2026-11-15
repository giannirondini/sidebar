import AppKit
import Testing
@testable import SidebArcCore

@MainActor
@Suite struct CustomToggleTests {
    private final class Target: NSObject {
        var calls = 0
        @objc func changed(_ sender: Any?) { calls += 1 }
    }

    @Test func programmaticChangesDoNotSendActions() {
        let toggle = CustomToggle(title: "Test")
        let target = Target()
        toggle.target = target
        toggle.action = #selector(Target.changed(_:))
        toggle.isOn = true
        #expect(target.calls == 0)
        toggle.performAction()
        #expect(!toggle.isOn)
        #expect(target.calls == 1)
    }
}
