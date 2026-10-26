import AppKit
import NextTermCore

/// A file or folder dropped on a remote tab, or an image pasted into one, copied to the host before anything is pasted
/// (RemoteUpload): one tar stream of what was dropped, made here off the main thread, sent over the tab's own ssh
/// connection into a new private folder there, then the paths there typed in as a drop types them. Only for the user's
/// own drop or paste in that tab; a tab that is not connected, a copy that fails, or a drop over the limits pastes
/// nothing and says why, in a line over the tab.
enum RemoteDrop {
    /// Copies `urls` (files and folders on this Mac) to the tab's host and pastes their paths there. `done` runs once it
    /// is over, copied or not (a pasted image's copy here is removed then).
    static func drop(_ urls: [URL], into tab: TerminalTab, done: (() -> Void)? = nil) {
        guard let remote = tab.remote, let path = tab.controlPath, tab.remoteConnected, !tab.disconnected else {
            done?()
            return tab.view.showNote("This tab is not connected, so the drop could not be copied to its server. Nothing was pasted.")
        }
        let names = urls.map(\.lastPathComponent)
        DispatchQueue.global(qos: .userInitiated).async {
            let bytes = urls.reduce(0) { $0 + size(of: $1, upTo: RemoteUpload.maxBytes + 1) }
            if let refusal = RemoteUpload.refusal(items: urls.count, bytes: bytes, names: names) {
                return DispatchQueue.main.async { done?(); tab.view.showNote(refusal) }
            }
            guard let stream = tarStream(urls) else {
                return DispatchQueue.main.async { done?(); tab.view.showNote("Next Term could not read what was dropped. Nothing was pasted.") }
            }
            DispatchQueue.main.async { send(stream, names: names, to: remote.host, path: path, tab: tab, done: done) }
        }
    }

    /// The stream goes as the script's stdin; then the paths are typed in, and the note says where they went. A copy
    /// that takes more than 2 s says so meanwhile.
    private static func send(_ stream: Data, names: [String], to host: RemoteHost, path: String, tab: TerminalTab, done finished: (() -> Void)?) {
        var done = false
        let what = names.count == 1 ? names[0] : "\(names.count) items"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if !done { tab.view.showNote("Copying \(what) to \(host.name)…") }
        }
        RemoteConnection.run(host, path: path, script: RemoteUpload.script, input: stream, timeout: 300) { output in
            done = true
            finished?()
            switch RemoteUpload.folder(output.output) {
            case .failure(let error):
                tab.view.showNote(output.timedOut ? "The copy to \(host.name) did not finish in time. Nothing was pasted." : error.text)
            case .success(let folder):
                guard !tab.exited, tab.view.acceptsInput else { return }
                tab.view.typeIn(RemoteUpload.pasted(folder: folder, names: names))
                tab.view.showNote("Copied \(what) to \(host.name):\(folder)/")
            }
        }
    }

    /// One tar stream of `urls`, each under its own name (`-C` its folder, then its name), or nil when tar could not
    /// read them. Links are kept as links, as a drop on this Mac would name them.
    private static func tarStream(_ urls: [URL]) -> Data? {
        var arguments = ["-cf", "-"]
        for url in urls { arguments += ["-C", url.deletingLastPathComponent().path, url.lastPathComponent] }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = arguments
        // Not macOS's resource forks and extended attributes as ._ files: the host gets the files alone.
        tar.environment = ["COPYFILE_DISABLE": "1"]
        let out = Pipe()
        tar.standardOutput = out
        tar.standardError = FileHandle.nullDevice
        tar.standardInput = FileHandle.nullDevice
        do { try tar.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        tar.waitUntilExit()
        return tar.terminationStatus == 0 ? data : nil
    }

    /// The bytes under `url`, counted up to `limit` (a folder's files, links not followed).
    private static func size(of url: URL, upTo limit: Int) -> Int {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let values = try? url.resourceValues(forKeys: Set(keys + [.isDirectoryKey])) else { return 0 }
        guard values.isDirectory == true else { return values.fileSize ?? 0 }
        var total = 0
        let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [])
        while let next = walk?.nextObject() as? URL, total <= limit {
            let file = try? next.resourceValues(forKeys: Set(keys))
            if file?.isRegularFile == true { total += file?.fileSize ?? 0 }
        }
        return total
    }
}
