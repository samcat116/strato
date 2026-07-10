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

/** Normalizes the string-backed form into request fields. */
export function parseDhcpForm(form: DhcpFormState): {
  dhcpEnabled: boolean;
  dnsServers: string[];
  domainName?: string;
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
    domainName: form.domainName.trim() || undefined,
    leaseTime: Number.isFinite(leaseTime) ? leaseTime : undefined,
  };
}

interface DHCPFieldsProps {
  value: DhcpFormState;
  onChange: (value: DhcpFormState) => void;
  disabled?: boolean;
}

/**
 * DHCP configuration inputs. When enabled, agents program OVN's DHCP responder
 * to deliver the control-plane-allocated IP plus this DNS/lease config to guests.
 */
export function DHCPFields({ value, onChange, disabled }: DHCPFieldsProps) {
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
        When on, agents answer guest DHCP requests with the allocated IP,
        gateway, and the DNS below. When off, VMs are configured statically via
        cloud-init.
      </p>

      <div className="space-y-2">
        <Label htmlFor="dnsServers" className="text-foreground">
          DNS servers
        </Label>
        <Input
          id="dnsServers"
          placeholder="1.1.1.1, 8.8.8.8"
          value={value.dnsServers}
          onChange={(e) => onChange({ ...value, dnsServers: e.target.value })}
          className="bg-background border-border text-foreground font-mono"
          disabled={disabled || !value.dhcpEnabled}
        />
        <p className="text-xs text-muted-foreground">
          Comma- or space-separated IPv4 or IPv6 addresses advertised over
          DHCP (each family&apos;s servers go to its own DHCP options).
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
          disabled={disabled || !value.dhcpEnabled}
        />
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
