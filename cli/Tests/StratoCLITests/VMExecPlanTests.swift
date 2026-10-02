import Testing

@testable import StratoCLICore

@Suite("VM exec invocation")
struct VMExecPlanTests {
    @Test(
        "No command selects the default shell; PTY requires both terminals", arguments: [true, false], [true, false])
    func shell(stdin: Bool, stdout: Bool) throws {
        let plan = try VMExecPlan(
            command: [], environment: [], forceTTY: false, noTTY: false,
            stdinIsTerminal: stdin, stdoutIsTerminal: stdout)
        #expect(plan.command == ["/bin/sh"])
        #expect(plan.tty == (stdin && stdout))
    }

    @Test("Arguments are preserved for remote shells and ordinary pipes")
    func command() throws {
        let command = ["/bin/sh", "-c", "cat | sed 's/a/b/'", "--flag"]
        let plan = try VMExecPlan(
            command: command, environment: ["A=one=two"], forceTTY: false,
            noTTY: false, stdinIsTerminal: false, stdoutIsTerminal: true)
        #expect(plan.command == command)
        #expect(plan.environment == ["A": "one=two"])
        #expect(!plan.tty)
    }

    @Test("TTY overrides fail before networking when invalid")
    func ttyOverrides() throws {
        #expect(throws: CLIError.self) {
            try VMExecPlan(
                command: [], environment: [], forceTTY: true, noTTY: true,
                stdinIsTerminal: true, stdoutIsTerminal: true)
        }
        #expect(throws: CLIError.self) {
            try VMExecPlan(
                command: [], environment: [], forceTTY: true, noTTY: false,
                stdinIsTerminal: false, stdoutIsTerminal: true)
        }
        #expect(
            try !VMExecPlan(
                command: [], environment: [], forceTTY: false, noTTY: true,
                stdinIsTerminal: true, stdoutIsTerminal: true
            ).tty)
    }
}
