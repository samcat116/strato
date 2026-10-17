import Vapor

extension Validate {
    static func guestCommand(command: [String], env: [String: String]?, workingDir: String?) throws {
        guard !command.isEmpty else {
            throw Abort(.badRequest, reason: "'command' must be a non-empty array of strings")
        }
        try Validate.stringList(command, "command", maxEntries: 128)
        try Validate.stringMap(env, "env", maxEntries: 128)
        _ = try Validate.text(workingDir, "workingDir")
        guard !command[0].isEmpty else {
            throw Abort(.badRequest, reason: "The executable in 'command' must not be empty")
        }
        guard command.allSatisfy({ !$0.contains("\0") }) else {
            throw Abort(.badRequest, reason: "Entries in 'command' must not contain NUL characters")
        }
        if let env {
            for (key, value) in env {
                guard
                    !key.isEmpty, !key.contains("="), !key.contains("\0"),
                    !value.contains("\0")
                else {
                    throw Abort(
                        .badRequest,
                        reason:
                            "Environment keys must be non-empty and contain neither '=' nor NUL; values must not contain NUL"
                    )
                }
            }
        }
        guard workingDir?.contains("\0") != true else {
            throw Abort(.badRequest, reason: "'workingDir' must not contain NUL characters")
        }
    }
}
