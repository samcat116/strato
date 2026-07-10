"use client";

import { useState } from "react";
import { Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { networksApi } from "@/lib/api/networks";
import type { Network } from "@/types/api";
import { toast } from "sonner";
import {
  DHCPFields,
  parseDhcpForm,
  type DhcpFormState,
} from "./dhcp-fields";

interface EditNetworkDialogProps {
  network: Network | null;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onUpdated?: () => void;
}

function dhcpFormFrom(network: Network): DhcpFormState {
  return {
    dhcpEnabled: network.dhcpEnabled,
    dnsServers: network.dnsServers.join(", "),
    domainName: network.domainName ?? "",
    leaseTime: network.leaseTime != null ? String(network.leaseTime) : "",
  };
}

/**
 * Edits a network's gateway and DHCP/DNS configuration. Subnet and name are
 * intentionally left to the create flow / server constraints; changing DHCP
 * settings re-syncs the config to agents so running guests pick it up on renew.
 */
export function EditNetworkDialog({
  network,
  open,
  onOpenChange,
  onUpdated,
}: EditNetworkDialogProps) {
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="bg-card border-border text-foreground">
        {network && (
          // Keyed on the network id so switching targets remounts the form with
          // fresh initial state — no effect needed to re-seed.
          <EditNetworkForm
            key={network.id}
            network={network}
            onOpenChange={onOpenChange}
            onUpdated={onUpdated}
          />
        )}
      </DialogContent>
    </Dialog>
  );
}

function EditNetworkForm({
  network,
  onOpenChange,
  onUpdated,
}: {
  network: Network;
  onOpenChange: (open: boolean) => void;
  onUpdated?: () => void;
}) {
  const [isLoading, setIsLoading] = useState(false);
  const [gateway, setGateway] = useState(network.gateway ?? "");
  const [enableIpv6, setEnableIpv6] = useState(false);
  const [dhcp, setDhcp] = useState<DhcpFormState>(() => dhcpFormFrom(network));

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!network.id) return;

    setIsLoading(true);
    try {
      await networksApi.update(network.id, {
        gateway: gateway.trim() || undefined,
        // Adding IPv6 is always safe (existing NICs stay v4); the server
        // generates a ULA /64 and re-syncs agents.
        ipv6Enabled: enableIpv6 ? true : undefined,
        ...parseDhcpForm(dhcp),
      });
      toast.success(`Network "${network.name}" updated`);
      onOpenChange(false);
      onUpdated?.();
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : "Failed to update network"
      );
    } finally {
      setIsLoading(false);
    }
  };

  return (
    <>
      <DialogHeader>
        <DialogTitle>Edit {network.name}</DialogTitle>
        <DialogDescription className="text-muted-foreground">
          Update the gateway and DHCP configuration. Subnet {network.subnet} is
          fixed here.
        </DialogDescription>
      </DialogHeader>
      <form onSubmit={handleSubmit}>
        <div className="space-y-4 py-4">
          <div className="space-y-2">
            <Label htmlFor="editGateway" className="text-foreground">
              Gateway
            </Label>
            <Input
              id="editGateway"
              placeholder="10.0.0.1"
              value={gateway}
              onChange={(e) => setGateway(e.target.value)}
              className="bg-background border-border text-foreground font-mono"
              disabled={isLoading}
            />
            <p className="text-xs text-muted-foreground">
              Changing the gateway only affects VMs created afterward.
            </p>
          </div>
          {network.subnet6 ? (
            <div className="space-y-2">
              <Label className="text-foreground">IPv6 subnet</Label>
              <p className="text-sm font-mono text-muted-foreground">
                {network.subnet6}
                {network.gateway6 ? ` (gateway ${network.gateway6})` : ""}
              </p>
            </div>
          ) : (
            <div className="flex items-center gap-2">
              <input
                id="editEnableIpv6"
                type="checkbox"
                checked={enableIpv6}
                onChange={(e) => setEnableIpv6(e.target.checked)}
                disabled={isLoading}
                className="h-4 w-4 accent-primary"
              />
              <Label htmlFor="editEnableIpv6" className="text-foreground">
                Enable IPv6 (generate a unique local /64)
              </Label>
            </div>
          )}
          <DHCPFields value={dhcp} onChange={setDhcp} disabled={isLoading} />
        </div>
        <DialogFooter>
          <Button
            type="button"
            variant="outline"
            onClick={() => onOpenChange(false)}
            className="border-input text-foreground/80 hover:bg-accent"
            disabled={isLoading}
          >
            Cancel
          </Button>
          <Button
            type="submit"
            className="bg-primary hover:bg-primary/90"
            disabled={isLoading}
          >
            {isLoading ? (
              <>
                <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                Saving...
              </>
            ) : (
              "Save Changes"
            )}
          </Button>
        </DialogFooter>
      </form>
    </>
  );
}
