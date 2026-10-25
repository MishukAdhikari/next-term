import Foundation
import NextTermCore

/// A run that Cancel can stop. Set from the main thread, read by the runner while it waits.
final class ShortcutStop: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var isSet: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

/// What Next Term asks of Apple's `shortcuts` command: the list of shortcuts, and one run with the task's text as its
/// input. Called off the main thread; each call waits for the command.
protocol ShortcutRunner: AnyObject, Sendable {
    /// What `shortcuts list --show-identifiers` printed, or nil when it couldn't run.
    func list() -> String?
    func run(arguments: [String], input: Data, limit: TimeInterval, stop: ShortcutStop) -> ShortcutList.Result
}

/// The real command, started with an argument array and never through a shell. Its standard input and output are
/// temporary files readable only by this user, not pipes: a pipe's end inherited by a process starting at the same
/// moment (a new tab's shell) would keep the command waiting for the end of its input. Both files are removed when
/// the run ends. A run's output is never read; its errors are never read either, since they can quote the input.
final class ProcessShortcutRunner: ShortcutRunner, @unchecked Sendable {
    func list() -> String? {
        var printed: Data?
        let result = start(ShortcutList.listArguments, input: nil, limit: 15, stop: ShortcutStop()) { printed = $0 }
        guard result == .finished(0), let printed else { return nil }
        return String(data: printed, encoding: .utf8)
    }

    func run(arguments: [String], input: Data, limit: TimeInterval, stop: ShortcutStop) -> ShortcutList.Result {
        start(arguments, input: input, limit: limit, stop: stop, read: nil)
    }

    /// Runs the command and hands its output to `read`, if given, when it exits on its own. Without a reader the
    /// output file is never loaded, so a shortcut that prints a large file costs nothing.
    private func start(_ arguments: [String], input: Data?, limit: TimeInterval, stop: ShortcutStop,
                       read: ((Data?) -> Void)?) -> ShortcutList.Result {
        // Cancel pressed while this waited its turn: the command never starts and gets nothing.
        if stop.isSet { return .stopped }
        let files = FileManager.default
        let temporary = files.temporaryDirectory
        let outputURL = temporary.appendingPathComponent("next-term-shortcut-out-\(UUID().uuidString)")
        let inputURL = temporary.appendingPathComponent("next-term-shortcut-in-\(UUID().uuidString)")
        let privateFile: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        defer {
            try? files.removeItem(at: outputURL)
            try? files.removeItem(at: inputURL)
        }
        guard files.createFile(atPath: outputURL.path, contents: nil, attributes: privateFile),
              let output = try? FileHandle(forWritingTo: outputURL) else { return .couldntStart }
        DescriptorSweep.closeOnExec(output.fileDescriptor)
        var inputFile: FileHandle?
        if let input {
            guard files.createFile(atPath: inputURL.path, contents: input, attributes: privateFile),
                  let handle = try? FileHandle(forReadingFrom: inputURL) else {
                try? output.close()
                return .couldntStart
            }
            DescriptorSweep.closeOnExec(handle.fileDescriptor)
            inputFile = handle
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ShortcutList.command)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = inputFile ?? FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            try? output.close()
            try? inputFile?.close()
            return .couldntStart
        }
        // The command has its own copies.
        try? output.close()
        try? inputFile?.close()
        if let cut = wait(exited, limit: limit, stop: stop) {
            end(process, exited)
            return cut
        }
        if let read { read(try? Data(contentsOf: outputURL)) }
        return .finished(process.terminationStatus)
    }

    /// Nil once the command exits; otherwise why it was cut short.
    private func wait(_ exited: DispatchSemaphore, limit: TimeInterval, stop: ShortcutStop) -> ShortcutList.Result? {
        let deadline = Date().addingTimeInterval(limit)
        while exited.wait(timeout: .now() + 0.2) == .timedOut {
            if stop.isSet { return .stopped }
            if Date() >= deadline { return .timedOut }
        }
        return nil
    }

    /// Asks the command to end, then makes it.
    private func end(_ process: Process, _ exited: DispatchSemaphore) {
        process.terminate()
        if exited.wait(timeout: .now() + 2) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = exited.wait(timeout: .now() + 2)
        }
    }
}

#if DEBUG
/// The self-test's runner: it starts no command and never runs the user's shortcuts. It keeps each run's arguments and
/// input, ends with the exit it is given, or never ends on its own until stopped or out of time.
final class FakeShortcutRunner: ShortcutRunner, @unchecked Sendable {
    struct Run: Equatable {
        let arguments: [String]
        let input: Data
    }

    private let lock = NSLock()
    private var listed: String?
    private var exit: Int32 = 0
    private var hangs = false
    private var made: [Run] = []
    private var listCalls = 0

    init(list: String?) {
        listed = list
    }

    var runs: [Run] { lock.withLock { made } }

    func answer(exit: Int32 = 0, hangs: Bool = false, list: String? = nil) {
        lock.withLock {
            self.exit = exit
            self.hangs = hangs
            if let list { listed = list }
        }
    }

    /// How often the shortcut list was asked for.
    var lists: Int { lock.withLock { listCalls } }

    func list() -> String? {
        lock.withLock {
            listCalls += 1
            return listed
        }
    }

    func run(arguments: [String], input: Data, limit: TimeInterval, stop: ShortcutStop) -> ShortcutList.Result {
        let (hangs, exit): (Bool, Int32) = lock.withLock {
            made.append(Run(arguments: arguments, input: input))
            return (self.hangs, self.exit)
        }
        guard hangs else { return .finished(exit) }
        let deadline = Date().addingTimeInterval(limit)
        while Date() < deadline {
            if stop.isSet { return .stopped }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return .timedOut
    }
}
#endif
