"use client";

/**
 * Toggle for the network's built-in DNS resolver (STR-40).
 *
 * A sibling of {@link MetadataField} rather than part of {@link DHCPFields},
 * for the same reason: the resolver is realized as an address on the network's
 * OVN localport and a CoreDNS on each hypervisor, not as a DHCP option, and it
 * is what the DHCP `dns_server` option *points at* rather than something DHCP
 * carries.
 *
 * It does change what the DNS servers field beside it means, though, which is
 * why {@link DHCPFields} takes the same boolean: with the resolver on, those
 * addresses are the resolver's upstream forwarders, not what guests are told.
 */
export function ResolverField({
  value,
  onChange,
  disabled,
}: {
  value: boolean;
  onChange: (value: boolean) => void;
  disabled?: boolean;
}) {
  return (
    <div className="space-y-2 rounded-md border border-border p-3">
      <label className="flex items-center gap-2 text-sm text-foreground">
        <input
          type="checkbox"
          checked={value}
          onChange={(e) => onChange(e.target.checked)}
          disabled={disabled}
          className="h-4 w-4 rounded border-input bg-background accent-blue-600"
        />
        Give guests a built-in DNS resolver
      </label>
      <p className="text-xs text-muted-foreground">
        Guests resolve through 169.254.169.253 (and fd00:ec2::253 on dual-stack
        networks), answered on their own hypervisor. It serves the DNS zones
        attached to this network in full — including the CNAME, TXT and SRV
        records the datapath cannot express.
      </p>
      <p className="text-xs text-muted-foreground">
        <strong>Upstream forwarding is not implemented yet</strong>, so turning
        this on trades external name resolution for the full internal record
        vocabulary: guests will resolve this network&apos;s names and nothing
        else. Leave it off unless that is the trade you want.
      </p>
    </div>
  );
}
