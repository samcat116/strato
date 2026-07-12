"use client";

import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Check, Copy, Loader2 } from "lucide-react";
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
import { useCreateUser, userErrorMessage } from "@/lib/hooks/use-users";
import { organizationsApi } from "@/lib/api/organizations";
import { toast } from "sonner";
import type { AdminCreateUserRequest, AdminCreateUserResponse } from "@/types/api";

// Sentinel because a Radix Select item can't have an empty-string value.
const NO_ORG = "__none__";
const ORG_ROLES = ["member", "admin"] as const;

interface CreateUserDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
}

export function CreateUserDialog({ open, onOpenChange }: CreateUserDialogProps) {
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="bg-card border-border text-foreground">
        {/* Keyed so the form fully resets each time the dialog reopens. */}
        <CreateUserForm key={open ? "open" : "closed"} onClose={() => onOpenChange(false)} />
      </DialogContent>
    </Dialog>
  );
}

function CreateUserForm({ onClose }: { onClose: () => void }) {
  const createUser = useCreateUser();
  const { data: organizations = [], isLoading: orgsLoading } = useQuery({
    queryKey: ["organizations"],
    queryFn: organizationsApi.list,
  });
  const [username, setUsername] = useState("");
  const [email, setEmail] = useState("");
  const [displayName, setDisplayName] = useState("");
  const [isSystemAdmin, setIsSystemAdmin] = useState(false);
  const [organizationId, setOrganizationId] = useState(NO_ORG);
  const [role, setRole] = useState<(typeof ORG_ROLES)[number]>("member");
  const [created, setCreated] = useState<AdminCreateUserResponse | null>(null);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    const payload: AdminCreateUserRequest = {
      username: username.trim(),
      email: email.trim(),
      displayName: displayName.trim(),
      isSystemAdmin,
    };
    if (organizationId !== NO_ORG) {
      payload.organizationId = organizationId;
      payload.role = role;
    }
    if (!payload.username || !payload.email || !payload.displayName) {
      toast.error("Username, email and display name are required");
      return;
    }

    try {
      const result = await createUser.mutateAsync(payload);
      setCreated(result);
      toast.success(`Created ${payload.username}`);
    } catch (error) {
      toast.error(userErrorMessage(error, "Failed to create user"));
    }
  };

  // Success view: surface the one-time claim link so the admin can share it.
  if (created) {
    return <ClaimLinkView result={created} onClose={onClose} />;
  }

  return (
    <>
      <DialogHeader>
        <DialogTitle>Create User</DialogTitle>
        <DialogDescription className="text-muted-foreground">
          Creates a local account and generates a one-time invitation link the
          new user opens to set up their passkey.
        </DialogDescription>
      </DialogHeader>

      <form onSubmit={handleSubmit}>
        <div className="space-y-4 py-4">
          <div className="space-y-2">
            <Label htmlFor="newUsername" className="text-foreground">
              Username
            </Label>
            <Input
              id="newUsername"
              value={username}
              onChange={(e) => setUsername(e.target.value)}
              placeholder="jdoe"
              className="bg-background border-border text-foreground"
              disabled={createUser.isPending}
              autoFocus
            />
          </div>

          <div className="space-y-2">
            <Label htmlFor="newEmail" className="text-foreground">
              Email
            </Label>
            <Input
              id="newEmail"
              type="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              placeholder="jdoe@example.com"
              className="bg-background border-border text-foreground"
              disabled={createUser.isPending}
            />
          </div>

          <div className="space-y-2">
            <Label htmlFor="newDisplayName" className="text-foreground">
              Display name
            </Label>
            <Input
              id="newDisplayName"
              value={displayName}
              onChange={(e) => setDisplayName(e.target.value)}
              placeholder="Jane Doe"
              className="bg-background border-border text-foreground"
              disabled={createUser.isPending}
            />
          </div>

          <label className="flex items-center gap-2 text-sm text-foreground/80">
            <input
              type="checkbox"
              checked={isSystemAdmin}
              onChange={(e) => setIsSystemAdmin(e.target.checked)}
              disabled={createUser.isPending}
              className="h-4 w-4 rounded border-border accent-primary"
            />
            Grant system administrator rights
          </label>

          <div className="space-y-2">
            <Label htmlFor="newOrg" className="text-foreground">
              Organization <span className="text-muted-foreground">(optional)</span>
            </Label>
            <Select
              value={organizationId}
              onValueChange={setOrganizationId}
              disabled={createUser.isPending || orgsLoading}
            >
              <SelectTrigger
                id="newOrg"
                className="bg-background border-border text-foreground"
              >
                <SelectValue
                  placeholder={orgsLoading ? "Loading..." : "No organization"}
                />
              </SelectTrigger>
              <SelectContent className="bg-card border-border">
                <SelectItem
                  value={NO_ORG}
                  className="text-foreground focus:bg-accent focus:text-accent-foreground"
                >
                  No organization
                </SelectItem>
                {organizations.map((org) => (
                  <SelectItem
                    key={org.id}
                    value={org.id}
                    className="text-foreground focus:bg-accent focus:text-accent-foreground"
                  >
                    {org.name}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            <p className="text-xs text-muted-foreground">
              Leave unset to manage membership yourself later.
            </p>
          </div>

          {organizationId !== NO_ORG && (
            <div className="space-y-2">
              <Label htmlFor="newOrgRole" className="text-foreground">
                Role
              </Label>
              <Select
                value={role}
                onValueChange={(v) => setRole(v as (typeof ORG_ROLES)[number])}
                disabled={createUser.isPending}
              >
                <SelectTrigger
                  id="newOrgRole"
                  className="bg-background border-border text-foreground capitalize"
                >
                  <SelectValue />
                </SelectTrigger>
                <SelectContent className="bg-card border-border">
                  {ORG_ROLES.map((r) => (
                    <SelectItem
                      key={r}
                      value={r}
                      className="text-foreground capitalize focus:bg-accent focus:text-accent-foreground"
                    >
                      {r}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
          )}
        </div>

        <DialogFooter>
          <Button
            type="button"
            variant="outline"
            className="border-input"
            onClick={onClose}
            disabled={createUser.isPending}
          >
            Cancel
          </Button>
          <Button
            type="submit"
            className="bg-primary hover:bg-primary/90"
            disabled={createUser.isPending}
          >
            {createUser.isPending ? (
              <>
                <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                Creating...
              </>
            ) : (
              "Create User"
            )}
          </Button>
        </DialogFooter>
      </form>
    </>
  );
}

function ClaimLinkView({
  result,
  onClose,
}: {
  result: AdminCreateUserResponse;
  onClose: () => void;
}) {
  const [copied, setCopied] = useState(false);

  // Prefer the current frontend origin — that's where /claim is served and
  // where the passkey ceremony must run — falling back to the server-built URL.
  const claimUrl =
    typeof window !== "undefined"
      ? `${window.location.origin}/claim?token=${result.claimToken}`
      : result.claimUrl;

  const expires = result.claimExpiresAt
    ? new Date(result.claimExpiresAt).toLocaleString()
    : null;

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(claimUrl);
      setCopied(true);
      toast.success("Invitation link copied");
      setTimeout(() => setCopied(false), 2000);
    } catch {
      toast.error("Couldn't copy — select and copy the link manually");
    }
  };

  return (
    <>
      <DialogHeader>
        <DialogTitle>Invite {result.user.username}</DialogTitle>
        <DialogDescription className="text-muted-foreground">
          Share this one-time link so {result.user.displayName} can set up their
          passkey. It won&apos;t be shown again
          {expires ? ` and expires ${expires}` : ""}.
        </DialogDescription>
      </DialogHeader>

      <div className="space-y-3 py-4">
        <Label className="text-foreground">Invitation link</Label>
        <div className="flex items-center gap-2">
          <Input
            readOnly
            value={claimUrl}
            onFocus={(e) => e.currentTarget.select()}
            className="bg-background border-border text-foreground font-mono text-xs"
          />
          <Button
            type="button"
            variant="outline"
            size="icon"
            className="border-input shrink-0"
            onClick={copy}
            aria-label="Copy invitation link"
          >
            {copied ? (
              <Check className="h-4 w-4 text-green-600" />
            ) : (
              <Copy className="h-4 w-4" />
            )}
          </Button>
        </div>
      </div>

      <DialogFooter>
        <Button
          type="button"
          className="bg-primary hover:bg-primary/90"
          onClick={onClose}
        >
          Done
        </Button>
      </DialogFooter>
    </>
  );
}
