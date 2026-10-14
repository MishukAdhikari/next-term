#if DEBUG
import AppKit
import NextTermCore

/// Progress for a long MCP call, through the real `nxtrm mcp` with a 1-second interval (NEXTTERM_TEST_MCP_PROGRESS_SECONDS,
/// read only in a DEBUG build): a stand-in OpenCode works in a background tab, and wait_for_tab waits on it.
extension SelfTest {
    /// OpenCode 1.19's working footer for 10 seconds, under its title, then gone.
    static let opencodeWorkingStandIn = #"""
    #!/bin/sh
    printf '\033[?1049h\033]2;OC | Stand-in\007\033[2J\033[H'
    printf '%s\n' '  ┃  run true' '' '   ■■⬝⬝⬝⬝ esc interrupt                              ctrl+p commands'
    sleep 10
    printf '\033[?1049l'
    """#

    /// A wait_for_tab of 3 seconds with a progress token gets at least two progress lines with that token, then its
    /// answer, and nothing after it. One of 2 seconds without a token gets only its answer.
    static func opencodeProgressChecks(_ c: TerminalWindowController, dir: URL) async {
        let server = MCPControlServer.shared
        let folder = dir.appendingPathComponent("progress")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let standIn = folder.appendingPathComponent("opencode")
        try? opencodeWorkingStandIn.write(to: standIn, atomically: true, encoding: .utf8)
        chmod(standIn.path, 0o755)
        guard server.isRunning, let mcp = MCPLineClient(socket: server.path, progressSeconds: 1) else {
            return check(false, "MCP progress: `nxtrm mcp` starts")
        }
        defer { mcp.close() }
        let tab = c.addTab(directory: nil, select: false)
        defer { c.remove(tab) }
        guard await wait(20, { tab.status.integrated }) else { return check(false, "MCP progress: the stand-in's tab starts its shell") }
        tab.view.send(txt: "PATH=\(folder.path):$PATH opencode\r")
        let working = await wait(6) { tab.status.state == .working && tab.status.screenSynced }
        guard working else { return check(false, "MCP progress: the stand-in's tab works", tab.status.state.rawValue) }

        let token = "selftest-progress"
        let tabID = tab.id.uuidString.lowercased()
        func waitCall(_ id: Int, seconds: Int, meta: [String: Any]?) {
            var params: [String: Any] = ["name": "wait_for_tab", "arguments": ["tab_id": tabID, "timeout_seconds": seconds]]
            if let meta { params["_meta"] = meta }
            mcp.send(["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": params])
        }
        let isProgress: ([String: Any]) -> Bool = { $0["method"] as? String == "notifications/progress" }
        let steps: ([[String: Any]]) -> [Int] = { lines in
            lines.compactMap { ($0["params"] as? [String: Any])?["progress"] as? Int }
        }

        waitCall(1, seconds: 3, meta: ["progressToken": token])
        let answered = await wait(15) { mcp.lines.contains { $0["id"] as? Int == 1 } }
        await pause(2.5) // two intervals more: nothing may follow the answer
        let lines = mcp.lines
        let answerAt = lines.firstIndex { $0["id"] as? Int == 1 } ?? lines.count
        let before = lines[..<answerAt].filter(isProgress)
        let after = lines[answerAt...].filter(isProgress)
        let tokens = before.compactMap { ($0["params"] as? [String: Any])?["progressToken"] as? String }
        let rising = steps(Array(before)) == (0..<before.count).map { $0 + 1 }
        let itsToken = tokens.count == before.count && tokens.allSatisfy { $0 == token }
        let progressed = answered && before.count >= 2 && itsToken && rising
        check(progressed && after.isEmpty,
              "MCP progress: a long call with a progress token gets progress every interval, and none after its answer",
              "answered \(answered), \(before.count) before (steps \(steps(Array(before)))), \(after.count) after")

        let seen = mcp.lines.count
        waitCall(2, seconds: 2, meta: nil)
        let plainAnswered = await wait(15) { mcp.lines.contains { $0["id"] as? Int == 2 } }
        let plain = mcp.lines.dropFirst(seen)
        check(plainAnswered && !plain.contains(where: isProgress),
              "MCP progress: a call without a progress token gets only its answer", "\(plain.count) lines")

        tab.view.send(txt: "\u{03}")
        _ = await wait(4) { !tab.status.running }
    }
}

/// An agent's side of `nxtrm mcp` that keeps every line it reads, notifications included (MCPTestClient waits for
/// answers by id only), with a progress interval of the test's own in the bridge's environment.
final class MCPLineClient: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var buffer = Data()

    init?(socket: String, progressSeconds: Double) {
        process.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        process.arguments = ["--cli", "mcp"]
        var environment = ProcessInfo.processInfo.environment
        environment[MCPServer.socketVariable] = socket
        environment["NEXTTERM_TEST_MCP_PROGRESS_SECONDS"] = String(progressSeconds)
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.lock.lock()
            self.buffer.append(data)
            self.lock.unlock()
        }
        guard (try? process.run()) != nil else { return nil }
    }

    func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        input.fileHandleForWriting.write(data)
    }

    /// Every whole line read so far, in order.
    var lines: [[String: Any]] {
        lock.lock()
        let text = String(decoding: buffer, as: UTF8.self)
        lock.unlock()
        return text.split(separator: "\n").compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        }
    }

    func close() {
        try? input.fileHandleForWriting.close()
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }
}
#endif
