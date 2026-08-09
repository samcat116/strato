import Foundation
import Logging

/// One chassis-side listener lifecycle change.
public enum MetadataServerAction: Sendable, Equatable {
    case start(networkId: UUID)
    case stop(networkId: UUID)
}

/// Pure diff for the listener fleet, mirroring `ChassisServiceReconciler` —
/// same input, same nil contract, and living beside it for the same reason: the
/// half that *stops* things is the half worth asserting.
public enum MetadataServerReconciler {

    /// `desired` nil ≙ a control plane that predates `metadataEnabled`: no
    /// actions at all, so silence is never read as "stop every listener". An
    /// empty (non-nil) list *is* an opinion and stops all of them.
    public static func actions(desired: [UUID], running: Set<UUID>) -> [MetadataServerAction] {
        let wanted = Set(desired)
        var actions: [MetadataServerAction] = []
        for networkId in wanted.subtracting(running).sorted(by: { $0.uuidString < $1.uuidString }) {
            actions.append(.start(networkId: networkId))
        }
        for networkId in running.subtracting(wanted).sorted(by: { $0.uuidString < $1.uuidString }) {
            actions.append(.stop(networkId: networkId))
        }
        return actions
    }
}

/// A running listener, from the agent's side.
public protocol MetadataServerHandle: Sendable {
    /// False once the child has exited, however it exited.
    var isRunning: Bool { get }
    /// Push a new servable set. Throws if the channel to the child is gone.
    func push(_ snapshot: MetadataSnapshot) throws
    func terminate()
}

/// How listeners are started. Injected so the supervisor's lifecycle can be
/// asserted without spawning processes or needing a namespace.
public protocol MetadataServerSpawning: Sendable {
    /// True when the network's namespace exists on this host. A listener cannot
    /// bind before then, and the namespace is created by a different reconcile
    /// pass, so this is an ordinary state rather than an error.
    func namespaceExists(networkId: UUID) -> Bool
    /// Every network this host already has a metadata namespace for.
    ///
    /// This is what a restarting agent knows before any sync arrives: the
    /// namespaces are host state that outlives the process. Without it the
    /// durable metadata copy would be pointless, because the listeners that
    /// would serve it do not exist until the control plane is reachable again —
    /// which is the outage the copy was written for.
    func existingNamespaces() -> [UUID]
    func spawn(networkId: UUID) throws -> any MetadataServerHandle
}

/// Keeps one metadata listener running per network this chassis serves
/// (STR-56).
///
/// ## Why a child process per namespace
///
/// ADR 0003 puts each network's metadata interface in its own namespace, and
/// leaves this issue to choose how a listener gets in there. A child under
/// `ip netns exec` is simply *in* the namespace and binds normally — no
/// `setns(2)`, which Swift's Glibc overlay does not even export, and no risk of
/// stranding a thread of the agent's shared concurrency pool in a tenant
/// namespace. It also buys fault isolation where it matters most: this is the
/// only code in the agent parsing bytes a guest chose, and a crash costs one
/// network's listener rather than the reconciler.
///
/// ## Level-triggered, like everything around it
///
/// Driven by the same `metadataNetworks` list the chassis reconcile consumes, so
/// there is no second input to drift. A listener that fails to start is simply
/// not running, and the next sync tries again: syncs are the retry timer, which
/// is why there is no backoff bookkeeping here to get wrong.
public actor MetadataServerSupervisor {
    private let spawner: any MetadataServerSpawning
    private let logger: Logger
    private var listeners: [UUID: any MetadataServerHandle] = [:]
    /// Networks whose last start attempt failed, so a repeated failure logs once
    /// loudly and then quietly. A host with no `ip` binary would otherwise emit
    /// a warning every sync forever.
    private var reportedFailures: Set<UUID> = []

    public init(spawner: any MetadataServerSpawning, logger: Logger) {
        self.spawner = spawner
        self.logger = logger
    }

    /// Converge the listener fleet, then push each one its network's snapshot.
    ///
    /// `snapshot` is asked for per network rather than handed a map, so the
    /// caller does not have to build payloads for networks that turn out not to
    /// be running.
    public func reconcile(desired: [UUID], snapshot: (UUID) -> MetadataSnapshot) async {
        // A child that died on its own is not running, whatever the map says.
        // Dropping it here is what makes the next start action a restart.
        for (networkId, handle) in listeners where !handle.isRunning {
            logger.warning(
                "Metadata listener exited; it will be restarted on this sync",
                metadata: ["networkId": .string(networkId.uuidString)])
            listeners.removeValue(forKey: networkId)
        }

        for action in MetadataServerReconciler.actions(desired: desired, running: Set(listeners.keys)) {
            switch action {
            case .start(let networkId): start(networkId)
            case .stop(let networkId): stop(networkId)
            }
        }

        for (networkId, handle) in listeners {
            do {
                try handle.push(snapshot(networkId))
            } catch {
                // The channel is gone, so the child is on its way out. Reap it
                // now rather than pushing into a closed pipe every sync.
                logger.warning(
                    "Could not push metadata to its listener; restarting it on the next sync",
                    metadata: [
                        "networkId": .string(networkId.uuidString), "error": .string("\(error)"),
                    ])
                handle.terminate()
                listeners.removeValue(forKey: networkId)
            }
        }
    }

    public func shutdown() async {
        for handle in listeners.values { handle.terminate() }
        listeners = [:]
    }

    /// The networks currently served. Test seam.
    public func runningNetworks() -> Set<UUID> { Set(listeners.keys) }

    // MARK: - Pieces

    private func start(_ networkId: UUID) {
        guard spawner.namespaceExists(networkId: networkId) else {
            // The ordinary state on the pass that creates the namespace: the
            // chassis reconcile and this one are separate steps, and the next
            // sync finds it there. Not a failure, so not a warning.
            logger.debug(
                "Metadata namespace is not present yet; deferring its listener",
                metadata: ["networkId": .string(networkId.uuidString)])
            return
        }
        do {
            listeners[networkId] = try spawner.spawn(networkId: networkId)
            reportedFailures.remove(networkId)
            logger.info(
                "Started metadata listener", metadata: ["networkId": .string(networkId.uuidString)])
        } catch {
            let message: Logger.Message =
                "Could not start the metadata listener; guests on this network will not read their metadata"
            let metadata: Logger.Metadata = [
                "networkId": .string(networkId.uuidString), "error": .string("\(error)"),
            ]
            // Loud once per transition, quiet on repeats: a persistently broken
            // host must not bury every other line in the log.
            if reportedFailures.insert(networkId).inserted {
                logger.warning(message, metadata: metadata)
            } else {
                logger.debug(message, metadata: metadata)
            }
        }
    }

    private func stop(_ networkId: UUID) {
        listeners.removeValue(forKey: networkId)?.terminate()
        reportedFailures.remove(networkId)
        logger.info("Stopped metadata listener", metadata: ["networkId": .string(networkId.uuidString)])
    }
}
