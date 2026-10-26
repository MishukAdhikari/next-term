import Darwin
import Foundation

/// The other processes that have a file open, for the question before editing a database: "it may belong
/// to an app that is running now" names them when there are any. libproc's proc_listpidspath looks
/// through every process this user may inspect, so it runs off the main thread.
public enum FileHolders {
    /// The names of the processes, other than this one, that have `path` or its -wal file open, each once.
    public static func processes(holding path: String) -> [String] {
        let me = getpid()
        var names: [String] = []
        let all = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard all > 0 else { return [] }
        for file in [path, path + "-wal"] where FileManager.default.fileExists(atPath: file) {
            var pids = [pid_t](repeating: 0, count: Int(all) / MemoryLayout<pid_t>.size + 64)
            let bytes = proc_listpidspath(UInt32(PROC_ALL_PIDS), 0, file, UInt32(PROC_LISTPIDSPATH_EXCLUDE_EVTONLY),
                                          &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
            guard bytes > 0 else { continue }
            for pid in pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size) where pid > 0 && pid != me {
                var buffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
                guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
                let name = String(cString: buffer)
                if !names.contains(name) { names.append(name) }
            }
        }
        return names
    }
}
