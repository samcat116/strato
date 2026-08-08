"use client";

import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";

/**
 * DHCP/DNS form state, shared by the create and edit network dialogs. DNS
 * servers and lease time are held as strings while editing and normalized on
 * submit via {@link parseDhcpForm}.
 */
export interface DhcpFormState {
  dhcpEnabled: boolean;
  /** Comma- or space-separated list while editing. */
  dnsServers: string;
  domainName: string;
  /** Seconds, as a string while editing. */
  leaseTime: string;
}

export const emptyDhcpForm: DhcpFormState = {
  dhcpEnabled: true,
  dnsServers: "",
  domainName: "",
  leaseTime: "",
};

/**
 * Normalizes the string-backed form into request fields.
 *
 * An emptied search domain goes out as `""`, not `undefined`: the update
 * endpoint reads an absent field as "leave alone", so sending `undefined` would
 * make clearing the field impossible — and would leave a network holding a
 * domain that predates validation permanently unsaveable, since every later
 * edit resubmits the whole form and fails on a value the user did try to
 * remove. The empty string is the documented clearing gesture, and the create
 * path reads it as absent.
 */
export function parseDhcpForm(form: DhcpFormState): {
  dhcpEnabled: boolean;
  dnsServers: string[];
  domainName: string;
  leaseTime?: number;
} {
  const dnsServers = form.dnsServers
    .split(/[\s,]+/)
    .map((s) => s.trim())
    .filter(Boolean);
  const leaseTime = form.leaseTime.trim()
    ? Number(form.leaseTime.trim())
    : undefined;
  return {
    dhcpEnabled: form.dhcpEnabled,
    dnsServers,
    domainName: form.domainName.trim(),
    leaseTime: Number.isFinite(leaseTime) ? leaseTime : undefined,
  };
}

interface DHCPFieldsProps {
  value: DhcpFormState;
  onChange: (value: DhcpFormState) => void;
  disabled?: boolean;
  /**
   * Whether the network's built-in resolver is on. Only relabels the DNS
   * servers field — with the resolver on, those addresses are its upstream
   * forwarders rather than what guests are told (STR-40). The field itself is
   * unchanged, so the two readings share one input.
   */
  resolverEnabled?: boolean;
}

/**
 * DHCP and DNS configuration inputs. DHCP decides how guests are addressed:
 * when enabled, agents program OVN's DHCP responder to deliver the
 * control-plane-allocated IP plus this DNS/lease config. The DNS servers and
 * search domain reach guests either way — over DHCP when it's on, and through
 * cloud-init's `nameservers` block on statically addressed NICs when it's off —
 * so only lease time is gated on the checkbox.
 *
 * The two paths differ in when they converge, which the help text spells out:
 * DHCP guests re-read the config on renew, while the NoCloud seed keys on a
 * stable `instance-id`, so a static NIC applies this DNS once at VM creation
 * and never again.
 */
export function DHCPFields({
  value,
  onChange,
  disabled,
  resolverEnabled = false,
}: DHCPFieldsProps) {
  return (
    <div className="space-y-4 rounded-md border border-border p-3">
      <label className="flex items-center gap-2 text-sm text-foreground">
        <input
          type="checkbox"
          checked={value.dhcpEnabled}
          onChange={(e) => onChange({ ...value, dhcpEnabled: e.target.checked })}
          disabled={disabled}
          className="h-4 w-4 rounded border-input bg-background accent-blue-600"
        />
        Manage guest addressing with OVN DHCP
      </label>
      <p className="text-xs text-muted-foreground">
        When on, agents answer guest DHCP requests with the allocated IP and
        gateway, and running guests pick up edits to the DNS below on their next
        renew. When off, VMs are configured statically via cloud-init, which
        applies that DNS once at VM creation — later edits reach only VMs
        created after them.
      </p>

      <div className="space-y-2">
        <Label htmlFor="dnsServers" className="text-foreground">
          {resolverEnabled ? "Upstream DNS forwarders" : "DNS servers"}
        </Label>
        <Input
          id="dnsServers"
          placeholder="1.1.1.1, 8.8.8.8"
          value={value.dnsServers}
          onChange={(e) => onChange({ ...value, dnsServers: e.target.value })}
          className="bg-background border-border text-foreground font-mono"
          disabled={disabled}
          aria-describedby="dnsServersHelp"
        />
        <p id="dnsServersHelp" className="text-xs text-muted-foreground">
          {resolverEnabled ? (
            <>
              Comma- or space-separated IPv4 or IPv6 addresses. The
              network&apos;s built-in resolver forwards to these for names it
              doesn&apos;t serve itself; guests are pointed at the resolver, not
              at these. Leaving it empty means internal names resolve and
              everything else is refused.
            </>
          ) : (
            <>
              Comma- or space-separated IPv4 or IPv6 addresses. Advertised over
              DHCP when it&apos;s on (each family&apos;s servers go to its own
              DHCP option), and written into cloud-init&apos;s nameservers on
              statically addressed NICs.
            </>
          )}
        </p>
      </div>

      <div className="space-y-2">
        <Label htmlFor="domainName" className="text-foreground">
          Search domain (optional)
        </Label>
        <Input
          id="domainName"
          placeholder="internal.example.com"
          value={value.domainName}
          onChange={(e) => onChange({ ...value, domainName: e.target.value })}
          className="bg-background border-border text-foreground"
          disabled={disabled}
          aria-describedby="domainNameHelp"
        />
        <p id="domainNameHelp" className="text-xs text-muted-foreground">
          Appended to unqualified hostname lookups — a DHCP option when DHCP is
          on, the cloud-init search list otherwise. Must be fully qualified: at
          least two labels, like a DNS zone name.
        </p>
      </div>

      <div className="space-y-2">
        <Label htmlFor="leaseTime" className="text-foreground">
          Lease time (seconds, optional)
        </Label>
        <Input
          id="leaseTime"
          type="number"
          min={1}
          placeholder="3600"
          value={value.leaseTime}
          onChange={(e) => onChange({ ...value, leaseTime: e.target.value })}
          className="bg-background border-border text-foreground font-mono"
          disabled={disabled || !value.dhcpEnabled}
        />
      </div>
    </div>
  );
}
