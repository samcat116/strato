"use client";

import { useState } from "react";
import Link from "next/link";
import { Loader2, AlertTriangle } from "lucide-react";
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
import { sandboxesApi } from "@/lib/api/sandboxes";
import { useAcceptedMutation } from "@/lib/hooks/use-accepted-mutation";
import { useNetworks } from "@/lib/hooks/use-networks";
import { useSecurityGroups } from "@/lib/hooks/use-security-groups";
import { useProjectContext } from "@/providers";
import { toast } from "sonner";
import { MAX_SECURITY_GROUPS_PER_NIC } from "@/types/api";

interface CreateSandboxDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onCreated?: () => void;
}

const EMPTY_FORM = {
  name: "",
  image: "",
  cpus: "1",
  memory: "1",
  entrypoint: "",
  cmd: "",
  env: "",
  workingDir: "",
  ttlSeconds: "",
  // "" means no network, which for a sandbox is a legitimate outcome rather
  // than an unfilled field — unlike VM create, where a network is required.
  networkId: "",
};

/** Splits a command-line-style string into argv, dropping empty tokens. */
function parseArgv(value: string): string[] | undefined {
  const parts = value.trim().split(/\s+/).filter(Boolean);
  return parts.length > 0 ? parts : undefined;
}

/**
 * Parses `KEY=VALUE` lines into an env map. Blank lines are ignored; the value
 * keeps everything after the first `=` (so `FOO=a=b` yields `a=b`).
 */
function parseEnv(value: string): Record<string, string> {
  const env: Record<string, string> = {};
  for (const line of value.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    const eq = trimmed.indexOf("=");
    if (eq <= 0) continue;
    env[trimmed.slice(0, eq).trim()] = trimmed.slice(eq + 1);
  }
  return env;
}

export function CreateSandboxDialog({
  open,
  onOpenChange,
  onCreated,
}: CreateSandboxDialogProps) {
  const { isLoading, run } = useAcceptedMutation();
  const [quotaError, setQuotaError] = useState<string | null>(null);
  const [formData, setFormData] = useState(EMPTY_FORM);
  const [securityGroupIds, setSecurityGroupIds] = useState<string[]>([]);

  // The sandbox is created in the project selected in the header switcher.
  const { currentProject } = useProjectContext();
  const projectId = currentProject?.id;

  const { data: networks = [] } = useNetworks(projectId);
  const { data: securityGroups = [], isError: securityGroupsFailed } =
    useSecurityGroups(projectId);

  const toggleSecurityGroup = (id: string) => {
    setSecurityGroupIds((prev) =>
      prev.includes(id) ? prev.filter((g) => g !== id) : [...prev, id]
    );
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!formData.name.trim()) {
      toast.error("Please enter a sandbox name");
      return;
    }
    if (!formData.image.trim()) {
      toast.error("Please enter an OCI image reference");
      return;
    }

    setQuotaError(null);
    const GB = 1024 * 1024 * 1024; // 1 GiB in bytes; the API field is named `memory`
    const env = parseEnv(formData.env);
    const ttl = parseInt(formData.ttlSeconds, 10);
    // Creation is asynchronous: the server accepts the request and returns
    // the sandbox with the generation it is converging on, which the
    // MutationWatcher follows and reports on completion.
    await run({
      request: () =>
        sandboxesApi.create({
          name: formData.name.trim(),
          image: formData.image.trim(),
          projectId,
          cpus: parseInt(formData.cpus, 10) || 1,
          memory: (parseInt(formData.memory, 10) || 1) * GB,
          entrypoint: parseArgv(formData.entrypoint),
          cmd: parseArgv(formData.cmd),
          ...(Object.keys(env).length > 0 ? { env } : {}),
          workingDir: formData.workingDir.trim() || undefined,
          ...(Number.isFinite(ttl) && ttl > 0 ? { ttlSeconds: ttl } : {}),
          // Both omitted without a network: the server rejects
          // `securityGroupIds` with no NIC to attach them to, and omitting them
          // *with* a network means the project's default group rather than none.
          ...(formData.networkId
            ? {
                networkId: formData.networkId,
                ...(securityGroupIds.length > 0 ? { securityGroupIds } : {}),
              }
            : {}),
        }),
      watch: {
        kind: "create",
        resourceKind: "sandbox",
        resourceName: formData.name.trim(),
      },
      errorMessage: "Failed to create sandbox",
      successMessage: `Creating sandbox "${formData.name.trim()}"`,
      onSuccess: () => {
        onOpenChange(false);
        onCreated?.();
        setFormData(EMPTY_FORM);
        setSecurityGroupIds([]);
        setQuotaError(null);
      },
      // Quota rejections surface inline with a pointer to the quotas page,
      // since resolving them means editing a quota rather than the form.
      onError: (message) => {
        if (/quota/i.test(message)) {
          setQuotaError(message);
          return true;
        }
        return false;
      },
    });
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="bg-card border-border text-foreground max-h-[90vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>Create Sandbox</DialogTitle>
          <DialogDescription className="text-muted-foreground">
            Boot a microVM from an OCI image
          </DialogDescription>
        </DialogHeader>
        <form onSubmit={handleSubmit}>
          <div className="space-y-4 py-4">
            {quotaError && (
              <div className="flex items-start gap-2 rounded-md border border-red-500/40 bg-red-500/10 p-3 text-sm text-red-700">
                <AlertTriangle className="h-4 w-4 mt-0.5 shrink-0" />
                <div className="space-y-1">
                  <p>{quotaError}</p>
                  <Link
                    href="/quotas"
                    className="inline-block font-medium text-red-800 underline hover:text-red-800"
                  >
                    Review resource quotas
                  </Link>
                </div>
              </div>
            )}
            <div className="space-y-2">
              <Label htmlFor="name" className="text-foreground">
                Sandbox Name
              </Label>
              <Input
                id="name"
                placeholder="my-sandbox"
                value={formData.name}
                onChange={(e) =>
                  setFormData({ ...formData, name: e.target.value })
                }
                className="bg-background border-border text-foreground"
                disabled={isLoading}
              />
            </div>

            <div className="space-y-2">
              <Label htmlFor="image" className="text-foreground">
                OCI Image
              </Label>
              <Input
                id="image"
                placeholder="ghcr.io/acme/worker:v3"
                value={formData.image}
                onChange={(e) =>
                  setFormData({ ...formData, image: e.target.value })
                }
                className="bg-background border-border text-foreground font-mono text-xs"
                disabled={isLoading}
              />
              <p className="text-xs text-muted-foreground">
                A container image reference. Private registries use the pull
                credentials configured for the project.
              </p>
            </div>

            <div className="grid grid-cols-2 gap-4">
              <div className="space-y-2">
                <Label htmlFor="cpus" className="text-foreground">
                  vCPUs
                </Label>
                <Input
                  id="cpus"
                  type="number"
                  min="1"
                  value={formData.cpus}
                  onChange={(e) =>
                    setFormData({ ...formData, cpus: e.target.value })
                  }
                  className="bg-background border-border text-foreground"
                  disabled={isLoading}
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="memory" className="text-foreground">
                  Memory (GiB)
                </Label>
                <Input
                  id="memory"
                  type="number"
                  min="1"
                  value={formData.memory}
                  onChange={(e) =>
                    setFormData({ ...formData, memory: e.target.value })
                  }
                  className="bg-background border-border text-foreground"
                  disabled={isLoading}
                />
              </div>
            </div>

            <div className="space-y-2">
              <Label htmlFor="entrypoint" className="text-foreground">
                Entrypoint{" "}
                <span className="text-muted-foreground">(optional)</span>
              </Label>
              <Input
                id="entrypoint"
                placeholder="/usr/bin/app"
                value={formData.entrypoint}
                onChange={(e) =>
                  setFormData({ ...formData, entrypoint: e.target.value })
                }
                className="bg-background border-border text-foreground font-mono text-xs"
                disabled={isLoading}
              />
              <p className="text-xs text-muted-foreground">
                Overrides the image entrypoint. Leave blank to use the image
                default.
              </p>
            </div>

            <div className="space-y-2">
              <Label htmlFor="cmd" className="text-foreground">
                Command{" "}
                <span className="text-muted-foreground">(optional)</span>
              </Label>
              <Input
                id="cmd"
                placeholder="--flag value"
                value={formData.cmd}
                onChange={(e) =>
                  setFormData({ ...formData, cmd: e.target.value })
                }
                className="bg-background border-border text-foreground font-mono text-xs"
                disabled={isLoading}
              />
              <p className="text-xs text-muted-foreground">
                Arguments passed to the entrypoint, split on spaces.
              </p>
            </div>

            <div className="space-y-2">
              <Label htmlFor="env" className="text-foreground">
                Environment{" "}
                <span className="text-muted-foreground">(optional)</span>
              </Label>
              <textarea
                id="env"
                placeholder={"KEY=value\nOTHER=value"}
                value={formData.env}
                onChange={(e) =>
                  setFormData({ ...formData, env: e.target.value })
                }
                disabled={isLoading}
                rows={3}
                className="w-full px-3 py-2 bg-background border border-border text-foreground rounded-md text-xs font-mono focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent disabled:opacity-50 disabled:cursor-not-allowed"
              />
              <p className="text-xs text-muted-foreground">
                One <code>KEY=value</code> per line. Merged over the image&apos;s
                environment.
              </p>
            </div>

            <div className="grid grid-cols-2 gap-4">
              <div className="space-y-2">
                <Label htmlFor="workingDir" className="text-foreground">
                  Working Dir{" "}
                  <span className="text-muted-foreground">(optional)</span>
                </Label>
                <Input
                  id="workingDir"
                  placeholder="/app"
                  value={formData.workingDir}
                  onChange={(e) =>
                    setFormData({ ...formData, workingDir: e.target.value })
                  }
                  className="bg-background border-border text-foreground font-mono text-xs"
                  disabled={isLoading}
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="ttlSeconds" className="text-foreground">
                  TTL (seconds){" "}
                  <span className="text-muted-foreground">(optional)</span>
                </Label>
                <Input
                  id="ttlSeconds"
                  type="number"
                  min="1"
                  placeholder="3600"
                  value={formData.ttlSeconds}
                  onChange={(e) =>
                    setFormData({ ...formData, ttlSeconds: e.target.value })
                  }
                  className="bg-background border-border text-foreground"
                  disabled={isLoading}
                />
              </div>
            </div>

            <div className="space-y-2">
              <Label htmlFor="network" className="text-foreground">
                Network
              </Label>
              <select
                id="network"
                value={formData.networkId}
                onChange={(e) =>
                  setFormData({ ...formData, networkId: e.target.value })
                }
                disabled={isLoading || networks.length === 0}
                className="w-full h-9 px-3 py-2 bg-background border border-border text-foreground rounded-md text-sm focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent disabled:opacity-50 disabled:cursor-not-allowed"
              >
                {/* Not `disabled`, unlike VM create: a sandbox with no
                    interface is a supported outcome, not an unfilled field. */}
                <option value="">No network</option>
                {networks
                  .filter((network) => network.id)
                  .map((network) => (
                    <option key={network.id} value={network.id!}>
                      {network.name} ({network.subnet})
                    </option>
                  ))}
              </select>
              <p className="text-xs text-muted-foreground">
                {networks.length === 0
                  ? "This project has no networks yet. The sandbox will be created without an interface."
                  : "Optional. With a network, the sandbox's IP is allocated automatically; without one it has no interface."}
              </p>
            </div>

            {formData.networkId && securityGroups.length > 0 && (
              <div className="space-y-2">
                <Label className="text-foreground">Security Groups</Label>
                <div className="space-y-1 rounded-md border border-border p-3 max-h-36 overflow-y-auto">
                  {securityGroups.map((group) => {
                    const checked = securityGroupIds.includes(group.id);
                    // Block checking one past the server-enforced per-NIC cap.
                    const atLimit =
                      !checked &&
                      securityGroupIds.length >= MAX_SECURITY_GROUPS_PER_NIC;
                    return (
                      <label
                        key={group.id}
                        className="flex items-center gap-2 text-sm text-foreground"
                      >
                        <input
                          type="checkbox"
                          checked={checked}
                          onChange={() => toggleSecurityGroup(group.id)}
                          disabled={isLoading || atLimit}
                          className="h-4 w-4 rounded border-input bg-background accent-blue-600"
                        />
                        {group.name}
                        {group.description && (
                          <span className="text-xs text-muted-foreground truncate">
                            {group.description}
                          </span>
                        )}
                      </label>
                    );
                  })}
                </div>
                <p className="text-xs text-muted-foreground">
                  Default group is used when none selected. An interface can
                  attach up to {MAX_SECURITY_GROUPS_PER_NIC} groups.
                </p>
              </div>
            )}
            {formData.networkId && securityGroupsFailed && (
              // A failed fetch must not read as "this project has no groups":
              // the sandbox would silently land on the default group only.
              <p className="text-xs text-red-600">
                Failed to load security groups — the sandbox will use the
                project&apos;s default group. Retry from the Security Groups
                page.
              </p>
            )}
          </div>
          <DialogFooter>
            <Button
              type="button"
              variant="outline"
              onClick={() => {
                setQuotaError(null);
                onOpenChange(false);
              }}
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
                "Create Sandbox"
              )}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
