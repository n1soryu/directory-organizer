import Foundation

/// Keeps the Mac from idle-sleeping while long work runs: Organize Now is minutes of model work,
/// and an idle sleep in the middle paused one for 34 minutes. Only idle *system* sleep is held
/// off: the display still sleeps, and closing the lid or choosing Sleep still works.
/// Ends with `end()`, or when the value is released.
public final class KeepAwake: @unchecked Sendable {
    private let lock = NSLock()
    private var activity: NSObjectProtocol?

    public init(reason: String) {
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: reason)
    }

    public var isActive: Bool { lock.withLock { activity != nil } }

    /// Lets the Mac sleep again. Safe to call more than once.
    public func end() {
        lock.withLock {
            guard let activity else { return }
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    deinit { end() }
}
