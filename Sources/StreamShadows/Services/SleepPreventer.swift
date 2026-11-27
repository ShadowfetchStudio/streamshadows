import Foundation
import IOKit.pwr_mgt

/// Prevents macOS display and system idle sleep while a livestream is active.
public final class SleepPreventer: @unchecked Sendable {
    private let lock = NSLock()
    private var assertionID: IOPMAssertionID = 0
    private var isActive = false

    public init() {}

    public func beginPreventingSleep(reason: String = "StreamShadows is actively livestreaming") {
        lock.lock()
        defer { lock.unlock() }
        guard !isActive else { return }

        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        if result == kIOReturnSuccess {
            assertionID = id
            isActive = true
        }
    }

    public func endPreventingSleep() {
        lock.lock()
        defer { lock.unlock() }
        guard isActive else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        isActive = false
    }

    deinit {
        endPreventingSleep()
    }
}
