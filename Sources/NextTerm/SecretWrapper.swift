import Darwin
import Foundation
import NextTermCore

/// `nxtrm secret run NAME[=ENVNAME]... -- <command> [arguments...]`, run as the app binary in its
/// command line mode. It asks the running Next Term over its socket at the fixed path, checks that the socket's owner is
/// this same program before it sends anything, waits for the user's answer, and on `allowed` execs the command with
/// the approved keys set and every other stored key's name removed.
///
/// It never writes to standard output, which is an MCP server's protocol channel: each ending is one line on standard
/// error and an exit code. It never ignores SIGPIPE (an ignored signal stays ignored after exec), never shuts its socket
/// for writing before the answer (the app would read that as leaving), and before `execve` it closes the socket and
/// every descriptor above 2, clears the signal mask, resets SIGPIPE, SIGINT and SIGTERM, and turns core dumps off.
enum SecretWrapper {
    /// The self-test's form, `--self-test-secret-wrapper <socket> <wait-seconds> secret run …`: its own socket and
    /// wait, with the peer checks as ever. Its `argv_full` can be set with `NEXTTERM_SELFTEST_ARGV_FULL` (JSON), so the
    /// self-test can check that a claim the kernel's argv doesn't match is refused. Only this form reads it, and only a
    /// debug build has it.
    #if DEBUG
    static func runSelfTest(_ arguments: [String]) -> Never {
        let claimed = ProcessInfo.processInfo.environment["NEXTTERM_SELFTEST_ARGV_FULL"]
            .flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) }
        let socket = arguments.count > 1 ? arguments[1] : ""
        let wait = arguments.count > 2 ? Double(arguments[2]) : nil
        run(Array(arguments.dropFirst(5)), socket: socket, wait: wait ?? SecretRun.wait,
            argvFull: claimed ?? CommandLine.arguments)
    }
    #endif

    /// Runs it with the arguments after `secret run`. `socket` and `wait` are the self-test's
    /// (`--self-test-secret-wrapper`); a wrapper otherwise uses the fixed path and ignores `NEXTTERM_MCP_SOCKET`.
    static func run(_ arguments: [String], socket path: String = MCPServer.socketPath(), wait: TimeInterval? = nil,
                    argvFull: [String] = CommandLine.arguments) -> Never {
        let invocation: SecretRun.Invocation
        switch SecretRun.parse(arguments) {
        case .failure: end(.usage, names: [], program: "")
        case .success(let parsed): invocation = parsed
        }
        let isTicket = invocation.ticket != nil
        let commandName = invocation.argv.first ?? ""
        var executable = ""
        if !isTicket {
            switch resolve(commandName, path: ProcessInfo.processInfo.environment["PATH"]) {
            case .found(let resolved): executable = resolved
            case .notFound: end(.notFound(commandName), names: invocation.names, program: commandName)
            case .cantRun: end(.cantRun(commandName), names: invocation.names, program: commandName)
            }
        }
        let program = (commandName as NSString).lastPathComponent

        let fd = connect(path)
        guard fd >= 0 else { end(.noSocket, names: invocation.names, program: program) }
        guard let token = PeerCode.auditToken(of: fd), PeerCode.current.isThisProgram(auditToken: token) else {
            close(fd)
            end(.peerCheck, names: invocation.names, program: program)
        }
        let environment = ProcessInfo.processInfo.environment
        let request = SecretRun.Request(names: invocation.names, map: invocation.map, argv: invocation.argv, executable: executable,
                                        directory: FileManager.default.currentDirectoryPath, argvFull: argvFull,
                                        warn: SecretRun.warnings(environment: environment), ticket: invocation.ticket)
        guard let line = request.line(), send(line, on: fd) else {
            close(fd)
            end(.noSocket, names: invocation.names, program: program)
        }
        let limit = wait ?? (isTicket ? SecretRun.ticketWait : SecretRun.wait)
        var reply: Data
        switch SecretRun.readAnswer(from: fd, within: limit) {
        case .line(let line): reply = line
        case .timedOut:
            close(fd)
            end(isTicket ? .timedOutTicket : .timedOut, names: invocation.names, program: program)
        case .closed:
            // Next Term quit, or restarted for an update, before it answered: the request is gone, not waiting.
            close(fd)
            end(.closed, names: invocation.names, program: program)
        case .tooLong:
            close(fd)
            end(.answer(.refused, name: nil, until: nil), names: invocation.names, program: program)
        }
        let answer = SecretRun.Answer.decode(reply)
        SecretBytes.wipe(&reply)
        guard let answer else {
            close(fd)
            end(.answer(.refused, name: nil, until: nil), names: invocation.names, program: program)
        }
        let names = answer.names ?? invocation.names
        guard answer.status == .allowed else {
            close(fd)
            let until = answer.until.map { Date(timeIntervalSince1970: $0) }
            end(.answer(answer.status, name: answer.name, until: until), names: names, program: program)
        }

        var argv = invocation.argv
        var target = executable
        if isTicket {
            // The command and folder Next Term holds for the ticket, never the typed line's.
            guard let ticketArgv = answer.argv, let first = ticketArgv.first, let directory = answer.directory, chdir(directory) == 0 else {
                close(fd)
                end(.answer(.refused, name: nil, until: nil), names: names, program: program)
            }
            argv = ticketArgv
            target = first
            let shown = ticketArgv.count >= 3 ? SecretRun.programName(ofCommand: ticketArgv[2]) : (first as NSString).lastPathComponent
            say(SecretRun.ending(.answer(.allowed, name: nil, until: nil), names: names, program: shown).line)
        }
        let childEnvironment = SecretRun.environment(base: environment, answer: answer)
        close(fd)
        exec(target, argv: argv, environment: childEnvironment)
        end(.cantRun(commandName.isEmpty ? target : commandName), names: names, program: program)
    }

    // MARK: endings

    /// Its one line on standard error, then its exit code. Never standard output.
    static func end(_ ending: SecretRun.Ending, names: [String], program: String) -> Never {
        let result = SecretRun.ending(ending, names: names, program: program)
        say(result.line)
        exit(result.exit)
    }

    static func say(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    // MARK: finding the command

    enum Resolution: Equatable {
        case found(String)
        case notFound
        case cantRun
    }

    /// `command` as the wrapper's own `PATH` finds it: a path as given (from the working folder), else the first
    /// executable file of that name in `PATH`.
    static func resolve(_ command: String, path: String?) -> Resolution {
        guard !command.isEmpty else { return .notFound }
        if command.contains("/") {
            let full = command.hasPrefix("/") ? command
                : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(command)
            return check(full).map(Resolution.found) ?? (exists(full) ? .cantRun : .notFound)
        }
        var sawOne = false
        let folders = (path ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        for folder in folders where !folder.isEmpty {
            let candidate = (folder as NSString).appendingPathComponent(command)
            if let found = check(candidate) { return .found(found) }
            if exists(candidate) { sawOne = true }
        }
        return sawOne ? .cantRun : .notFound
    }

    /// The path when it is a plain file this user may run.
    private static func check(_ path: String) -> String? {
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, access(path, X_OK) == 0 else { return nil }
        return path
    }

    private static func exists(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0
    }

    // MARK: the socket

    /// A connection to the app's socket, closed on exec, with no SIGPIPE: -1 when nothing answers there.
    static func connect(_ path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            return -1
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            close(fd)
            return -1
        }
        return fd
    }

    static func send(_ data: Data, on fd: Int32) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count, let base = raw.baseAddress {
                let written = write(fd, base + offset, raw.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    // MARK: exec

    /// Replaces this process with the command: every descriptor above 2 closed, the signal mask cleared, SIGPIPE,
    /// SIGINT and SIGTERM at their defaults, no core dumps. Returns only when `execve` fails.
    static func exec(_ path: String, argv: [String], environment: [String: String]) {
        var noCore = rlimit(rlim_cur: 0, rlim_max: 0)
        setrlimit(RLIMIT_CORE, &noCore)
        closeDescriptors(above: 2)
        var empty = sigset_t()
        sigemptyset(&empty)
        sigprocmask(SIG_SETMASK, &empty, nil)
        for signalNumber in [SIGPIPE, SIGINT, SIGTERM] { signal(signalNumber, SIG_DFL) }
        let arguments = argv.map { strdup($0) } + [nil]
        let variables = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        execve(path, arguments, variables)
        for pointer in arguments { free(pointer) }
        for pointer in variables { free(pointer) }
    }

    /// Closes every open descriptor above `last`, as the kernel lists them.
    static func closeDescriptors(above last: Int32) {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let size = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return }
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 16)
        let filled = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, &descriptors, Int32(descriptors.count * stride))
        guard filled > 0 else { return }
        for descriptor in descriptors.prefix(Int(filled) / stride) where descriptor.proc_fd > last {
            close(descriptor.proc_fd)
        }
    }
}
