import Foundation
import IOKit.pwr_mgt
import Testing
@testable import OrganizerCore

/// Asks macOS itself whether this process is holding off idle sleep, so the test checks the real
/// effect, not just a flag.
private func preventsIdleSleep() -> Bool {
    var byProcess: Unmanaged<CFDictionary>?
    guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
          let all = byProcess?.takeRetainedValue() as? [AnyHashable: Any] else { return false }
    let mine = all.first { key, _ in (key as? NSNumber)?.int32Value == ProcessInfo.processInfo.processIdentifier }?.value
    let assertions = mine as? [[String: Any]] ?? []
    return assertions.contains { ($0[kIOPMAssertionTypeKey] as? String) == kIOPMAssertionTypePreventUserIdleSystemSleep }
}

@Suite(.serialized) struct KeepAwakeTests {
    @Test func holdsOffIdleSleepUntilEnded() {
        let awake = KeepAwake(reason: "test")
        #expect(awake.isActive)
        #expect(preventsIdleSleep())
        awake.end()
        awake.end()  // twice is fine
        #expect(!awake.isActive)
        #expect(!preventsIdleSleep())
    }

    @Test func endsWhenReleased() {
        do {
            let awake = KeepAwake(reason: "test")
            #expect(awake.isActive)
        }
        #expect(!preventsIdleSleep())
    }
}
