import Darwin
import Foundation
import NextTermCore

/// The tunnel's watchdog (KTD12, R42): `nxtrm tunnel-guard`, a hidden mode of this binary that Next Term starts beside
/// every tunnel child, the ssh child of "Your own server" included. macOS has no parent-death signal, so this waits
/// on both Next Term's pid and the child's with kqueue `NOTE_EXIT`.
///
/// - Next Term exits first, however it exits (a crash and a force quit included): the child is ended while its start
///   time still matches, SIGTERM, again after 1 second, SIGKILL after 3, so it is gone within 5 seconds. Then the
///   watchdog exits.
/// - The child exits first, on Turn Off or by itself: the watchdog exits.
/// - Either is gone, or its pid is another process's, before the watch begins: the same, at once.
///
/// It signals only the process its arguments name, by pid and start time (`RemoteAccessProcesses`). A hang-up or an
/// interrupt sent to a terminal's whole group doesn't stop it.
enum RemoteAccessTunnelGuard {
    /// Starts the watchdog for `child`, owned by this Next Term. Nil when it could not start; the pid record then
    /// lets the next launch end a child a crash left.
    @discardableResult
    static func launch(child: pid_t, start: RemoteAccessPidRecord.Start) -> Process? {
        guard let ownerStart = RemoteAccessProcesses.start(of: getpid()) else { return nil }
        let targets = RemoteAccessGuardTargets(owner: getpid(), ownerStart: ownerStart, child: child, childStart: start)
        return launch(targets)
    }

    /// Starts the watchdog for any owner, so the self-test can give it a stand-in parent (U12).
    @discardableResult
    static func launch(_ targets: RemoteAccessGuardTargets) -> Process? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        process.arguments = ["--cli"] + targets.arguments
        process.environment = TerminalEnvironment.clean(ProcessInfo.processInfo.environment)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            NSLog("Next Term: Remote access could not start the tunnel's watchdog: %@", "\(error)")
            return nil
        }
        return process
    }

    /// The watchdog itself, from `CommandLineTool.run`. Never returns.
    static func run(_ targets: RemoteAccessGuardTargets) -> Never {
        signal(SIGHUP, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        signal(SIGPIPE, SIG_IGN)
        let queue = kqueue()
        guard queue >= 0 else { exit(1) }
        // The child first: gone already, there is nothing to guard.
        guard !RemoteAccessProcesses.isGone(targets.child, start: targets.childStart),
              watch(targets.child, in: queue) else { exit(0) }
        guard !RemoteAccessProcesses.isGone(targets.owner, start: targets.ownerStart),
              watch(targets.owner, in: queue) else { end(targets) }
        while true {
            var event = kevent()
            let count = kevent(queue, nil, 0, &event, 1, nil)
            if count < 0 {
                if errno == EINTR { continue }
                // The kernel's watch failed: the child keeps a watch, once a second.
                poll(targets)
            }
            guard count > 0 else { continue }
            if event.ident == UInt(targets.child) { exit(0) }
            if event.ident == UInt(targets.owner) { end(targets) }
        }
    }

    /// Asks the kernel for `pid`'s exit. False when it is gone already (ESRCH) or can't be watched.
    private static func watch(_ pid: pid_t, in queue: Int32) -> Bool {
        let flags = UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT)
        var change = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: flags, fflags: NOTE_EXIT, data: 0,
                            udata: nil)
        return kevent(queue, &change, 1, nil, 0, nil) == 0
    }

    private static func poll(_ targets: RemoteAccessGuardTargets) -> Never {
        while true {
            if RemoteAccessProcesses.isGone(targets.child, start: targets.childStart) { exit(0) }
            if RemoteAccessProcesses.isGone(targets.owner, start: targets.ownerStart) { end(targets) }
            sleep(1)
        }
    }

    /// Next Term is gone: the child is ended while it is still the process the arguments name, then the watchdog exits.
    private static func end(_ targets: RemoteAccessGuardTargets) -> Never {
        RemoteAccessProcesses.endNow(targets.child, start: targets.childStart, from: .now())
        exit(0)
    }
}
