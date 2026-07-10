"use client";

import { useState } from "react";
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
import { useOrganization } from "@/providers/organization-provider";
import { toast } from "sonner";
import type { AgentRegistrationToken } from "@/types/api";

interface CreateTokenDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onCreated?: () => void;
}

export function CreateTokenDialog({
  open,
  onOpenChange,
  onCreated,
}: CreateTokenDialogProps) {
  const { currentOrg, organizations } = useOrganization();
  const [isLoading, setIsLoading] = useState(false);
  const [agentName, setAgentName] = useState("");
  const [expirationHours, setExpirationHours] = useState("24");
  // The org whose dedicated capacity this agent becomes; defaults to the
  // active organization.
  const [organizationId, setOrganizationId] = useState<string | undefined>(undefined);
  const [createdToken, setCreatedToken] = useState<AgentRegistrationToken | null>(null);
  const [copiedCommand, setCopiedCommand] = useState<
    "curl" | "join" | "docker" | "bootstrap" | null
  >(null);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!agentName.trim()) {
      toast.error("Please enter an agent name");
      return;
    }

    const targetOrgId = organizationId ?? currentOrg?.id;
    if (!targetOrgId) {
      toast.error("Please select an organization for this agent");
      return;
    }

    setIsLoading(true);
    try {
      const token = await agentsApi.createToken({
        agentName,
        expirationHours: parseInt(expirationHours) || 24,
        organizationId: targetOrgId,
      });
      setCreatedToken(token);
      onCreated?.();
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : "Failed to create token"
      );
    } finally {
      setIsLoading(false);
    }
  };

  const curlInstallCommand = createdToken
    ? `curl -fsSL https://raw.githubusercontent.com/samcat116/strato/main/deploy/agent/install.sh | sudo bash -s -- --registration-url '${createdToken.registrationURL}'`
    : "";
  const joinCommand = createdToken
    ? `strato-agent join '${createdToken.registrationURL}'`
    : "";
  const dockerJoinCommand = createdToken
    ? `docker run -d --name strato-agent --restart unless-stopped --device /dev/kvm -v /var/lib/strato:/var/lib/strato -v /etc/strato:/etc/strato ghcr.io/samcat116/strato-agent:latest join '${createdToken.registrationURL}'`
    : "";
  const bootstrapCommand = createdToken?.bootstrapCommand ?? "";

  const handleCopy = async (
    command: "curl" | "join" | "docker" | "bootstrap"
  ) => {
    const text =
      command === "curl"
        ? curlInstallCommand
        : command === "join"
          ? joinCommand
          : command === "docker"
            ? dockerJoinCommand
            : bootstrapCommand;
    if (!text) return;
    await navigator.clipboard.writeText(text);
    setCopiedCommand(command);
    toast.success(
      command === "curl"
        ? "Install command copied to clipboard"
        : command === "join"
          ? "Join command copied to clipboard"
          : command === "docker"
            ? "Docker command copied to clipboard"
            : "Bootstrap command copied to clipboard"
    );
    setTimeout(() => setCopiedCommand(null), 2000);
  };

  const handleClose = () => {
    onOpenChange(false);
    // Reset state after close animation
    setTimeout(() => {
      setAgentName("");
      setExpirationHours("24");
      setCreatedToken(null);
      setCopiedCommand(null);
    }, 200);
  };

  return (
    <Dialog open={open} onOpenChange={handleClose}>
      <DialogContent className="bg-card border-border text-foreground sm:max-w-2xl max-h-[85vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>
            {createdToken ? "Registration Token Created" : "Add Compute Agent"}
          </DialogTitle>
          <DialogDescription className="text-muted-foreground">
            {createdToken
              ? "Use this token to register your agent"
              : "Create a registration token for a new compute agent"}
          </DialogDescription>
        </DialogHeader>

        {createdToken ? (
          <div className="space-y-4 py-4 min-w-0">
            {bootstrapCommand && (
              <div className="p-4 bg-background rounded-lg border border-border">
                <Label className="text-muted-foreground text-sm">
                  Bootstrap the node (SPIRE attestation + agent join) with one
                  command:
                </Label>
                <div className="flex items-start gap-2 mt-2">
                  <code className="flex-1 min-w-0 p-2 bg-gray-950 rounded text-sm text-green-400 font-mono whitespace-pre-wrap break-all">
                    {bootstrapCommand}
                  </code>
                  <Button
                    size="sm"
                    variant="outline"
                    className="border-input shrink-0"
                    onClick={() => handleCopy("bootstrap")}
                  >
                    {copiedCommand === "bootstrap" ? (
                      <Check className="h-4 w-4 text-green-600" />
                    ) : (
                      <Copy className="h-4 w-4" />
                    )}
                  </Button>
                </div>
                <p className="text-sm text-muted-foreground mt-2">
                  Starts spire-agent with the one-time join token, waits for
                  the node&apos;s SVID, then joins the control plane. Both
                  tokens are single-use and expire together.
                </p>
              </div>
            )}

            {/* Token-only onboarding — hidden when a bootstrap command is
                present: the control plane requires mTLS then, so these
                commands (no SVID) would fail before token auth runs. */}
            {!bootstrapCommand && (
              <>
              <div className="p-4 bg-background rounded-lg border border-border">
                <Label className="text-muted-foreground text-sm">
                  {bootstrapCommand
                    ? "Or install + join without SPIRE (token auth only):"
                    : "Run this command on your hypervisor host:"}
                </Label>
                <div className="flex items-start gap-2 mt-2">
                  <code className="flex-1 min-w-0 p-2 bg-gray-950 rounded text-sm text-green-400 font-mono whitespace-pre-wrap break-all">
                    {curlInstallCommand}
                  </code>
                  <Button
                    size="sm"
                    variant="outline"
                    className="border-input shrink-0"
                    onClick={() => handleCopy("curl")}
                  >
                    {copiedCommand === "curl" ? (
                      <Check className="h-4 w-4 text-green-600" />
                    ) : (
                      <Copy className="h-4 w-4" />
                    )}
                  </Button>
                </div>
                <p className="text-sm text-muted-foreground mt-2">
                  Downloads the agent, installs QEMU/OVN dependencies and a
                  systemd service, then joins — and reconnects automatically
                  after restarts.
                </p>
              </div>

              <div className="space-y-2">
                <Label className="text-muted-foreground text-sm">
                  Or, if strato-agent is already installed, just join:
                </Label>
                <div className="flex items-start gap-2">
                  <code className="flex-1 min-w-0 p-3 bg-gray-950 rounded text-sm text-gray-200 font-mono whitespace-pre-wrap break-all">
                    {joinCommand}
                  </code>
                  <Button
                    size="sm"
                    variant="outline"
                    className="border-input shrink-0"
                    onClick={() => handleCopy("join")}
                  >
                    {copiedCommand === "join" ? (
                      <Check className="h-4 w-4 text-green-600" />
                    ) : (
                      <Copy className="h-4 w-4" />
                    )}
                  </Button>
                </div>
              </div>
              </>
            )}

            <div className="p-4 bg-blue-500/10 rounded-lg border border-blue-500/30">
              <p className="text-sm text-blue-800">
                <strong>Important:</strong> The token in this command is
                single-use and will not be shown again.
              </p>
              <p className="text-sm text-muted-foreground mt-2">
                Expires: {new Date(createdToken.expiresAt).toLocaleString()}
              </p>
            </div>

            {!bootstrapCommand && (
              <div className="space-y-2">
                <Label className="text-muted-foreground text-sm">
                  Or run the agent in Docker (Linux hosts):
                </Label>
                <div className="flex items-start gap-2">
                  <code className="flex-1 min-w-0 p-3 bg-gray-950 rounded text-sm text-gray-200 font-mono whitespace-pre-wrap break-all">
                    {dockerJoinCommand}
                  </code>
                  <Button
                    size="sm"
                    variant="outline"
                    className="border-input shrink-0"
                    onClick={() => handleCopy("docker")}
                  >
                    {copiedCommand === "docker" ? (
                      <Check className="h-4 w-4 text-green-600" />
                    ) : (
                      <Copy className="h-4 w-4" />
                    )}
                  </Button>
                </div>
              </div>
            )}
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
                <Label htmlFor="organization" className="text-foreground">
                  Organization
                </Label>
                <Select
                  value={organizationId ?? currentOrg?.id ?? ""}
                  onValueChange={setOrganizationId}
                  disabled={isLoading}
                >
                  <SelectTrigger
                    id="organization"
                    className="bg-background border-border text-foreground"
                  >
                    <SelectValue placeholder="Select an organization" />
                  </SelectTrigger>
                  <SelectContent>
                    {organizations.map((org) => (
                      <SelectItem key={org.id} value={org.id}>
                        {org.name}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
                <p className="text-sm text-muted-foreground">
                  The agent becomes dedicated capacity for this organization —
                  only its VMs will be scheduled onto it.
                </p>
              </div>
              <div className="space-y-2">
                <Label htmlFor="expiration" className="text-foreground">
                  Token Expiration (hours)
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
                disabled={isLoading}
              >
                {isLoading ? (
                  <>
                    <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                    Creating...
                  </>
                ) : (
                  "Create Token"
                )}
              </Button>
            </DialogFooter>
          </form>
        )}

        {createdToken && (
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
