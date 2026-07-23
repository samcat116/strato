"use client";

import { useEffect, useState } from "react";
import { Loader2, Copy, Check } from "lucide-react";
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
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { agentsApi } from "@/lib/api/agents";
import { useSites } from "@/lib/hooks/use-sites";
import { useOrganization } from "@/providers";
import { toast } from "sonner";
import type { AgentEnrollment } from "@/types/api";

interface CreateEnrollmentDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onCreated?: () => void;
}

export function CreateEnrollmentDialog({
  open,
  onOpenChange,
  onCreated,
}: CreateEnrollmentDialogProps) {
  // The agent becomes dedicated capacity for the org selected in the sidebar
  // switcher.
  const { currentOrg } = useOrganization();
  // Every enrollment must join a site (availability zone) in the current org.
  const { data: sites, isLoading: sitesLoading } = useSites();
  const [isLoading, setIsLoading] = useState(false);
  const [agentName, setAgentName] = useState("");
  const [siteId, setSiteId] = useState("");
  const [expirationHours, setExpirationHours] = useState("24");
  const [enrollment, setEnrollment] = useState<AgentEnrollment | null>(null);
  const [copied, setCopied] = useState(false);

  // Every org has at least a default site, so the common case is a single
  // option — preselect it so the operator only has to name the agent. With
  // multiple sites, leave the choice to them.
  useEffect(() => {
    if (!siteId && sites?.length === 1) {
      setSiteId(sites[0].id);
    }
  }, [sites, siteId]);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!agentName.trim()) {
      toast.error("Please enter an agent name");
      return;
    }

    if (!currentOrg) {
      toast.error("Select an organization before creating an enrollment");
      return;
    }

    if (!siteId) {
      toast.error("Select a site for the agent to join");
      return;
    }

    setIsLoading(true);
    try {
      const created = await agentsApi.createEnrollment({
        agentName,
        expirationHours: parseInt(expirationHours) || 24,
        organizationId: currentOrg.id,
        siteId,
      });
      setEnrollment(created);
      onCreated?.();
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : "Failed to create enrollment"
      );
    } finally {
      setIsLoading(false);
    }
  };

  const handleCopy = async () => {
    if (!enrollment?.bootstrapCommand) return;
    await navigator.clipboard.writeText(enrollment.bootstrapCommand);
    setCopied(true);
    toast.success("Bootstrap command copied to clipboard");
    setTimeout(() => setCopied(false), 2000);
  };

  const handleClose = () => {
    onOpenChange(false);
    // Reset state after close animation
    setTimeout(() => {
      setAgentName("");
      setSiteId("");
      setExpirationHours("24");
      setEnrollment(null);
      setCopied(false);
    }, 200);
  };

  return (
    <Dialog open={open} onOpenChange={handleClose}>
      <DialogContent className="bg-card border-border text-foreground sm:max-w-2xl max-h-[85vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>
            {enrollment ? "Agent Enrollment Created" : "Add Compute Agent"}
          </DialogTitle>
          <DialogDescription className="text-muted-foreground">
            {enrollment
              ? "Run this command on the hypervisor host to enroll the agent"
              : currentOrg
                ? `Create an enrollment for a new compute agent. The agent becomes dedicated capacity for ${currentOrg.name} — only its VMs will be scheduled onto it.`
                : "Create an enrollment for a new compute agent"}
          </DialogDescription>
        </DialogHeader>

        {enrollment ? (
          <div className="space-y-4 py-4 min-w-0">
            <div className="p-4 bg-background rounded-lg border border-border">
              <Label className="text-muted-foreground text-sm">
                Bootstrap the node (install, SPIRE attestation, agent join, host
                telemetry) with one command:
              </Label>
              <div className="flex items-start gap-2 mt-2">
                <code className="flex-1 min-w-0 p-2 bg-gray-950 rounded text-sm text-green-400 font-mono whitespace-pre-wrap break-all">
                  {enrollment.bootstrapCommand}
                </code>
                <Button
                  size="sm"
                  variant="outline"
                  className="border-input shrink-0"
                  onClick={handleCopy}
                >
                  {copied ? (
                    <Check className="h-4 w-4 text-green-600" />
                  ) : (
                    <Copy className="h-4 w-4" />
                  )}
                </Button>
              </div>
              <p className="text-sm text-muted-foreground mt-2">
                Starts spire-agent with the one-time join token, waits for the
                node&apos;s SVID, then joins the control plane over mTLS.
              </p>
            </div>

            <div className="p-4 bg-background rounded-lg border border-border space-y-3">
              <div className="flex flex-col gap-1 min-w-0">
                <Label className="text-muted-foreground text-sm">
                  SPIFFE ID
                </Label>
                <code className="text-sm font-mono text-foreground break-all">
                  {enrollment.spiffeId}
                </code>
              </div>
              <div className="flex flex-col gap-1 min-w-0">
                <Label className="text-muted-foreground text-sm">
                  Trust domain
                </Label>
                <code className="text-sm font-mono text-foreground break-all">
                  {enrollment.spire.trustDomain}
                </code>
              </div>
              <div className="flex flex-col gap-1 min-w-0">
                <Label className="text-muted-foreground text-sm">
                  SPIRE server
                </Label>
                <code className="text-sm font-mono text-foreground break-all">
                  {enrollment.spire.serverAddress}
                </code>
              </div>
            </div>

            <div className="p-4 bg-blue-500/10 rounded-lg border border-blue-500/30">
              <p className="text-sm text-blue-800">
                <strong>Important:</strong> The join token in this command is
                single-use and will not be shown again.
              </p>
              <p className="text-sm text-muted-foreground mt-2">
                Expires: {new Date(enrollment.expiresAt).toLocaleString()}
              </p>
            </div>
          </div>
        ) : (
          <form onSubmit={handleSubmit}>
            <div className="space-y-4 py-4">
              <div className="space-y-2">
                <Label htmlFor="agentName" className="text-foreground">
                  Agent Name
                </Label>
                <Input
                  id="agentName"
                  placeholder="my-hypervisor-01"
                  value={agentName}
                  onChange={(e) => setAgentName(e.target.value)}
                  className="bg-background border-border text-foreground"
                  disabled={isLoading}
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="site" className="text-foreground">
                  Site
                </Label>
                {!sitesLoading && sites && sites.length === 0 ? (
                  <p className="text-sm text-muted-foreground">
                    No sites exist in {currentOrg?.name ?? "this organization"}.
                    Create a site before enrolling an agent — every agent must
                    join an availability zone.
                  </p>
                ) : (
                  <Select
                    value={siteId}
                    onValueChange={setSiteId}
                    disabled={isLoading || sitesLoading}
                  >
                    <SelectTrigger
                      id="site"
                      className="bg-background border-border text-foreground"
                    >
                      <SelectValue
                        placeholder={
                          sitesLoading ? "Loading sites…" : "Select a site"
                        }
                      />
                    </SelectTrigger>
                    <SelectContent className="bg-card border-border">
                      {sites?.map((site) => (
                        <SelectItem
                          key={site.id}
                          value={site.id}
                          className="text-foreground focus:bg-accent focus:text-accent-foreground"
                        >
                          {site.name}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                )}
              </div>
              <div className="space-y-2">
                <Label htmlFor="expiration" className="text-foreground">
                  Enrollment Expiration (hours)
                </Label>
                <Input
                  id="expiration"
                  type="number"
                  min="1"
                  max="720"
                  value={expirationHours}
                  onChange={(e) => setExpirationHours(e.target.value)}
                  className="bg-background border-border text-foreground"
                  disabled={isLoading}
                />
              </div>
            </div>
            <DialogFooter>
              <Button
                type="button"
                variant="outline"
                onClick={handleClose}
                className="border-input text-foreground/80 hover:bg-accent"
                disabled={isLoading}
              >
                Cancel
              </Button>
              <Button
                type="submit"
                className="bg-primary hover:bg-primary/90"
                disabled={isLoading || !siteId}
              >
                {isLoading ? (
                  <>
                    <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                    Creating...
                  </>
                ) : (
                  "Create Enrollment"
                )}
              </Button>
            </DialogFooter>
          </form>
        )}

        {enrollment && (
          <DialogFooter>
            <Button
              onClick={handleClose}
              className="bg-primary hover:bg-primary/90"
            >
              Done
            </Button>
          </DialogFooter>
        )}
      </DialogContent>
    </Dialog>
  );
}
