import Foundation

/// Starting children one at a time. Foundation on Linux has no close-on-exec default for a child:
/// `run()` lists the descriptors open at that moment and closes those in the child, so a pipe, or
/// the socket another `Process` learns of its own child's exit through, made by another thread
/// after that list was read is inherited. A long-lived engine holding a short-lived git's exit
/// socket means the git is never seen to exit and `waitUntilExit()` waits for good; holding its
/// stdout means the read waiting for the end of it never ends.
enum Spawning {
    private static let lock = NSRecursiveLock()

    /// Runs `body`, which makes a child's pipes and starts it, while no other child is started
    /// and no other child's pipes are made.
    static func serialized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

extension Process {
    /// Lets go of a child that has exited, with the pipes it was given. Foundation on Linux keeps a
    /// finished `Process` alive until `waitUntilExit()` is called on it, because that call is the
    /// only place the run-loop source retaining it is dropped; a bridge that never called it kept
    /// every engine it had started, the minute's sign-in probe among them, and each one's stdout
    /// pipe, until the descriptor table was full and the server could no longer accept a
    /// connection. Called from a termination handler, which runs once the child is gone, it
    /// returns at once; call it from nowhere else that may also wait, since two waits race on the
    /// same source.
    func releaseFinished() {
        waitUntilExit()
    }

    /// Starts the child, trying again a few times while its program is busy. A file that is open
    /// for writing cannot be run (ETXTBSY), and that is briefly true of one nobody here is
    /// writing: a child another thread is forking holds a copy of every descriptor open at that
    /// moment, a script half-written a moment earlier among them, until it runs its own program.
    /// An engine binary being replaced by an update is refused the same way.
    func runAllowingBusyExecutable() throws {
        try Spawning.serialized { try runRetryingBusy() }
    }

    private func runRetryingBusy() throws {
        for attempt in 1...Self.busyAttempts {
            do {
                return try run()
            } catch where Self.programWasBusy(error) && attempt < Self.busyAttempts {
                usleep(useconds_t(attempt * 40_000))
            }
        }
    }

    private static let busyAttempts = 5

    private static func programWasBusy(_ error: Error) -> Bool {
        let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
        return underlying?.domain == NSPOSIXErrorDomain && underlying?.code == Int(ETXTBSY)
    }
}
