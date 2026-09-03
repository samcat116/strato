/// Re-observes libvirt domain definitions after every detach because a reboot
/// can restore the live interface from persistent configuration between steps.
public enum DomainNetworkDetachConvergence {
    public static func run(
        observe: () async throws -> DomainNetworkDetachPlan,
        detach: (DomainNetworkDetachScope) async throws -> Void
    ) async throws -> Bool {
        var didDetach = false
        while let scope = try await observe().scopes.first {
            didDetach = true
            try await detach(scope)
        }
        return didDetach
    }
}
