"use client";

import { DialogSubmitFooter } from "@/components/ui/dialog-submit-footer";

import { useState } from "react";
import {
  Dialog,
  DialogContent,
  DialogDescription,
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
import {
  useBindableRoles,
  useGrantProjectMember,
  projectMemberErrorMessage,
} from "@/lib/hooks";
import { toast } from "sonner";
import { warnAboutGrantCeilings } from "@/lib/grant-ceilings";

interface AddMemberDialogProps {
  projectId: string;
  open: boolean;
  onOpenChange: (open: boolean) => void;
}

export function AddMemberDialog({
  projectId,
  open,
  onOpenChange,
}: AddMemberDialogProps) {
  const grant = useGrantProjectMember(projectId);
  const { data: roles = [], isLoading: rolesLoading } = useBindableRoles(
    "project",
    projectId
  );
  const [email, setEmail] = useState("");
  const [role, setRole] = useState("");
  const selectedRole =
    role || roles.find((candidate) => candidate.name === "editor")?.id || roles[0]?.id || "";

  const handleClose = () => {
    onOpenChange(false);
    setTimeout(() => {
      setEmail("");
      setRole("");
    }, 200);
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    const trimmed = email.trim();
    if (!trimmed) {
      toast.error("Please enter the user's email address");
      return;
    }
    if (!selectedRole) {
      toast.error("No role is available for this project");
      return;
    }
    const roleName = roles.find((candidate) => candidate.id === selectedRole)?.name ?? selectedRole;
    try {
      const result = await grant.mutateAsync({ userEmail: trimmed, role: selectedRole });
      toast.success(`Granted ${trimmed} the ${roleName} role`);
      warnAboutGrantCeilings(result, `${trimmed}'s ${roleName} role`);
      handleClose();
    } catch (error) {
      toast.error(projectMemberErrorMessage(error, "Failed to add member"));
    }
  };

  return (
    <Dialog open={open} onOpenChange={handleClose}>
      <DialogContent className="bg-card border-border text-foreground">
        <DialogHeader>
          <DialogTitle>Add project member</DialogTitle>
          <DialogDescription className="text-muted-foreground">
            Grant an existing user a role on this project.
          </DialogDescription>
        </DialogHeader>

        <form onSubmit={handleSubmit}>
          <div className="space-y-4 py-4">
            <div className="space-y-2">
              <Label htmlFor="pmEmail" className="text-foreground">
                Email
              </Label>
              <Input
                id="pmEmail"
                type="email"
                placeholder="user@example.com"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                className="bg-background border-border text-foreground"
                disabled={grant.isPending}
                autoFocus
              />
              <p className="text-xs text-muted-foreground">
                The user must already have a Strato account.
              </p>
            </div>

            <div className="space-y-2">
              <Label htmlFor="pmRole" className="text-foreground">
                Role
              </Label>
              <Select
                value={selectedRole}
                onValueChange={setRole}
                disabled={grant.isPending || rolesLoading || roles.length === 0}
              >
                <SelectTrigger
                  id="pmRole"
                  className="bg-background border-border text-foreground"
                >
                  <SelectValue />
                </SelectTrigger>
                <SelectContent className="bg-card border-border">
                  {roles.map((candidate) => (
                    <SelectItem
                      key={candidate.id}
                      value={candidate.id}
                      className="text-foreground focus:bg-accent focus:text-accent-foreground"
                    >
                      {candidate.name}
                      {candidate.description && (
                        <> — <span className="text-muted-foreground">{candidate.description}</span></>
                      )}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
          </div>

          <DialogSubmitFooter
            submitLabel="Add member"
            pendingLabel="Adding..."
            isPending={grant.isPending}
            disabled={!selectedRole}
            onCancel={handleClose}
          />
        </form>
      </DialogContent>
    </Dialog>
  );
}
