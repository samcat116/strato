import CedarPolicy
import Foundation
import Vapor

// IAM phase 7 (issue #484): the symbolic-analysis seam.
//
// `CedarEngine` decides one request. This decides questions about *every*
// request: can a proposed grant reach anything a ceiling forbids? Denying at
// evaluation time is correct but produces a mystery; denying at write time
// produces an explanation, and that is what an analyzable policy language was
// chosen for (docs/architecture/iam.md).

/// The "type" of request an analysis reasons over. SymCC answers one of these
/// at a time, so the caller picks which ones can possibly matter — see
/// `GuardrailWriteCheck` for how the enumeration is kept to a handful.
struct CedarRequestEnvironment: Hashable, Sendable {
    let principalType: CedarEntityType
    let action: String
    let resourceType: CedarEntityType
}

/// The answer to one symbolic query.
struct GuardrailAnalysis: Sendable {
    /// Whether the property asked about holds for every request in the
    /// environment — that the sets are disjoint, or that one subsumes the
    /// other.
    let holds: Bool
    /// A concrete request violating the property, rendered for humans. Present
    /// only when it fails — it is what turns a denial into an explanation.
    let counterexample: String?
}

/// Why an analysis could not be performed.
///
/// The distinction is the whole point of the type: `unavailable` means the
/// question went unanswered, which the write path treats as `503`, while a
/// rejected query is a bug in what we generated and must not be mistaken for
/// a clean bill of health.
enum GuardrailAnalyzerError: Error, CustomStringConvertible {
    /// No solver is configured, or the configured one could not be run.
    case unavailable(String)
    /// The solver ran and failed, timed out, or died mid-query.
    case solverFailed(String)
    /// The symbolic compiler rejected the query itself.
    case rejected(String)

    var description: String {
        switch self {
        case .unavailable(let detail): return "symbolic analysis unavailable: \(detail)"
        case .solverFailed(let detail): return "solver failed: \(detail)"
        case .rejected(let detail): return "symbolic analysis rejected the query: \(detail)"
        }
    }
}

/// The seam the symbolic analyzer plugs in at.
///
/// A protocol for the same reason `CedarEngine` is one: the test harness
/// injects a stub so the suites that merely *write bindings* do not each need
/// an SMT solver on the machine, while the tests that are about this check run
/// against the real thing.
protocol GuardrailAnalyzer: Sendable {
    /// Whether any request in `environment` is allowed by both policy sets.
    func disjoint(
        schemaText: String,
        _ a: [CedarPolicySource],
        _ b: [CedarPolicySource],
        in environment: CedarRequestEnvironment
    ) async throws -> GuardrailAnalysis

    /// Whether everything `a` allows in `environment` is also allowed by `b` —
    /// subsumption. Not used on the write path; this is what proves the
    /// role-nesting invariant (`viewer ⊂ operator ⊂ editor ⊂ admin`) in CI,
    /// where the direction is the easy thing to get backwards.
    func implies(
        schemaText: String,
        _ a: [CedarPolicySource],
        _ b: [CedarPolicySource],
        in environment: CedarRequestEnvironment
    ) async throws -> GuardrailAnalysis
}

/// The production analyzer: swift-cedar's `SymbolicCompiler` over a local cvc5
/// process.
struct SymCCGuardrailAnalyzer: GuardrailAnalyzer {
    let solverPath: String
    /// Per-query wall-clock limit. Generous because this runs on policy writes
    /// — rare, and latency-tolerant by design — but finite, because a hung
    /// solver must surface as a failure the write path can act on rather than
    /// as a request that never returns.
    let timeoutMilliseconds: UInt32

    init(solverPath: String, timeoutMilliseconds: UInt32 = 30_000) {
        self.solverPath = solverPath
        self.timeoutMilliseconds = timeoutMilliseconds
    }

    func disjoint(
        schemaText: String,
        _ a: [CedarPolicySource],
        _ b: [CedarPolicySource],
        in environment: CedarRequestEnvironment
    ) async throws -> GuardrailAnalysis {
        try await run(schemaText: schemaText, a, b, in: environment) { compiler, x, y, schema, env in
            try await compiler.checkDisjoint(x, y, schema: schema, in: env)
        }
    }

    func implies(
        schemaText: String,
        _ a: [CedarPolicySource],
        _ b: [CedarPolicySource],
        in environment: CedarRequestEnvironment
    ) async throws -> GuardrailAnalysis {
        try await run(schemaText: schemaText, a, b, in: environment) { compiler, x, y, schema, env in
            try await compiler.checkImplies(x, y, schema: schema, in: env)
        }
    }

    private func run(
        schemaText: String,
        _ a: [CedarPolicySource],
        _ b: [CedarPolicySource],
        in environment: CedarRequestEnvironment,
        query: (SymbolicCompiler, PolicySet, PolicySet, CedarPolicy.Schema, RequestEnvironment)
            async throws -> CedarPolicy.AnalysisResult
    ) async throws -> GuardrailAnalysis {
        let compiler = SymbolicCompiler(
            solverPath: solverPath, timeoutMilliseconds: timeoutMilliseconds)
        do {
            let result = try await query(
                compiler,
                try policySet(a),
                try policySet(b),
                try CedarPolicy.Schema(schemaText),
                RequestEnvironment(
                    principalType: environment.principalType.rawValue,
                    action: environment.action,
                    resourceType: environment.resourceType.rawValue
                )
            )
            return GuardrailAnalysis(holds: result.holds, counterexample: result.counterexample)
        } catch CedarError.solver(let message) {
            throw GuardrailAnalyzerError.solverFailed(message)
        } catch {
            throw GuardrailAnalyzerError.rejected("\(error)")
        }
    }

    /// Parse each policy individually with its assembler-assigned id, the same
    /// way `SwiftCedarEngine` does — a set parsed as one blob gets positional
    /// `policy0` ids and could never name the guardrail it came from.
    private func policySet(_ policies: [CedarPolicySource]) throws -> PolicySet {
        try PolicySet(policies: try policies.map { try Policy($0.text, id: $0.id) })
    }
}

/// An analyzer that answers nothing, because no solver was found.
///
/// Every query throws `unavailable`, which the write path turns into a `503`.
/// This is the fail-closed half of the posture: a deployment with no solver
/// stops accepting the writes this check guards rather than accepting them
/// unchecked. It does not stop the deployment — eval-time guardrail
/// enforcement is untouched, and readiness deliberately does not depend on the
/// solver, because a solver outage should fail the writes it guards, not cycle
/// every pod.
struct UnavailableGuardrailAnalyzer: GuardrailAnalyzer {
    let reason: String

    func disjoint(
        schemaText: String,
        _ a: [CedarPolicySource],
        _ b: [CedarPolicySource],
        in environment: CedarRequestEnvironment
    ) async throws -> GuardrailAnalysis {
        throw GuardrailAnalyzerError.unavailable(reason)
    }

    func implies(
        schemaText: String,
        _ a: [CedarPolicySource],
        _ b: [CedarPolicySource],
        in environment: CedarRequestEnvironment
    ) async throws -> GuardrailAnalysis {
        throw GuardrailAnalyzerError.unavailable(reason)
    }
}

// MARK: - Resolution

extension Application {
    private struct GuardrailAnalyzerKey: StorageKey, LockKey {
        typealias Value = any GuardrailAnalyzer
    }

    /// This replica's symbolic analyzer.
    ///
    /// Settable so tests can inject one; the setter takes the same lock the
    /// lazy initializer does, so an injection cannot race a first read.
    var guardrailAnalyzer: any GuardrailAnalyzer {
        get { lazyService(GuardrailAnalyzerKey.self) { Self.resolveGuardrailAnalyzer(logger: logger) } }
        set {
            let lock = locks.lock(for: GuardrailAnalyzerKey.self)
            lock.lock()
            defer { lock.unlock() }
            setStorageValue(GuardrailAnalyzerKey.self, to: newValue)
        }
    }

    /// Locate the cvc5 executable the write-time check needs.
    ///
    /// `IAM_SYMCC_SOLVER_PATH` first, then `cvc5` on `PATH`. Resolution happens
    /// once, at first use, and its outcome is logged either way: a deployment
    /// that has quietly lost its solver is refusing binding writes, and the
    /// operator needs to be able to find out why from the logs rather than
    /// from a support ticket.
    static func resolveGuardrailAnalyzer(logger: Logger) -> any GuardrailAnalyzer {
        let environment = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let configured = environment["IAM_SYMCC_SOLVER_PATH"], !configured.isEmpty {
            candidates.append(configured)
        }
        let searchPath = environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        candidates += searchPath.split(separator: ":").map { "\($0)/cvc5" }

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            logger.info(
                "Symbolic guardrail analysis enabled", metadata: ["solver": .string(candidate)])
            return SymCCGuardrailAnalyzer(solverPath: candidate)
        }

        let reason =
            environment["IAM_SYMCC_SOLVER_PATH"].map {
                "IAM_SYMCC_SOLVER_PATH='\($0)' is not an executable file"
            } ?? "no cvc5 found via IAM_SYMCC_SOLVER_PATH or PATH"
        logger.error(
            """
            No SMT solver for the write-time guardrail check; binding writes will be refused. \
            Install cvc5 and set IAM_SYMCC_SOLVER_PATH.
            """,
            metadata: ["reason": .string(reason)])
        return UnavailableGuardrailAnalyzer(reason: reason)
    }
}
