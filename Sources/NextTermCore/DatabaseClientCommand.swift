import Foundation

/// The `mysql` or `psql` command a hand-off types into a new tab. The password is never in it: it goes
/// in a 0600 file the caller writes and deletes once the client has started, and the command only
/// names that file.
public enum DatabaseClientCommand {
    /// The client program for an engine, or nil (no terminal hand-off for it).
    public static func clients(for engine: DatabaseEngine) -> [String] {
        switch engine {
        case .mysql: return ["mysql", "mariadb"]
        case .mariadb: return ["mariadb", "mysql"]
        case .postgres, .cockroach: return ["psql"]
        default: return []
        }
    }

    public static func isPostgres(_ engine: DatabaseEngine) -> Bool { engine == .postgres || engine == .cockroach }

    /// The client's arguments, program first. `secretFile` is the option file (MySQL) or passfile (libpq).
    public static func arguments(for db: DetectedDatabase, program: String, secretFile: String?) -> [String] {
        if isPostgres(db.engine) {
            var info: [String] = []
            func add(_ key: String, _ value: String?) {
                guard let value, !value.isEmpty else { return }
                info.append("\(key)='\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'"))'")
            }
            add("host", db.socket ?? db.host)
            add("port", db.port.map(String.init))
            add("dbname", db.database)
            add("user", db.user)
            add("passfile", secretFile)
            return [program, info.joined(separator: " ")]
        }
        var args = [program]
        // MySQL reads --defaults-extra-file only as the first option.
        if let secretFile { args.append("--defaults-extra-file=" + secretFile) }
        if let socket = db.socket {
            args.append("--socket=" + socket)
        } else if let host = db.host {
            args.append("--host=" + host)
            if let port = db.port { args.append("--port=\(port)") }
        }
        if let user = db.user { args.append("--user=" + user) }
        if let database = db.database { args.append(database) }
        return args
    }

    /// The command line, quoted for the shell.
    public static func commandLine(for db: DetectedDatabase, program: String, secretFile: String?) -> String {
        arguments(for: db, program: program, secretFile: secretFile).map(ShellQuote.quote).joined(separator: " ")
    }

    /// What goes in the 0600 file: `[client] password="…"` for MySQL, a libpq passfile line for Postgres.
    public static func secretFileContents(for engine: DatabaseEngine, password: String) -> String {
        if isPostgres(engine) {
            let escaped = password.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ":", with: "\\:")
            return "*:*:*:*:\(escaped)\n"
        }
        let escaped = password.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "[client]\npassword=\"\(escaped)\"\n"
    }
}
