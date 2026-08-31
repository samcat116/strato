/// A transition a hypervisor backend pushed at the agent, rather than one the
/// agent went looking for (STR-135).
///
/// The payload is deliberately thin, because it is not evidence: everything
/// downstream of it re-reads the host and sends a full `ObservedStateReport`,
/// whose list semantics mean a partial answer would be worse than no answer.
/// So `reason` — and the VM id in the `.vm` case — exist for the log line, and
/// nothing keys behaviour on either.
public enum VMLifecycleChange: Sendable, Equatable {
    /// One VM on this host changed. `reason` is the backend's own name for the
    /// transition (`LibvirtDomain.lifecycleEventLabel(forRawEvent:)` for
    /// libvirt).
    case vm(id: String, reason: String)

    /// Everything this backend can see may have changed while it was not
    /// looking — the subscription was just (re-)established, so the window
    /// before it is unaccounted for.
    ///
    /// Handled identically to `.vm` today, and the split is diagnostic on
    /// purpose: this is the line an operator greps for to answer "did the agent
    /// notice libvirtd came back". Collapsing the two cases would erase that
    /// and save nothing.
    case resynchronize(reason: String)
}
