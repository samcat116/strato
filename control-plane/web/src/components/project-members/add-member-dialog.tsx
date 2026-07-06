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
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { useGrantProjectMember, projectMemberErrorMessage } from "@/lib/hooks";
import { toast } from "sonner";
import type { ProjectRole } from "@/types/api";

const ROLES: { value: ProjectRole; label: string; hint: string }[] = [
  { value: "admin", label: "Admin", hint: "Full control, including members" },
  { value: "member", label: "Member", hint: "Create and manage resources" },
  { value: "viewer", label: "Viewer", hint: "Read-only access" },
];

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
  const [email, setEmail] = useState("");
  const [role, setRole] = useState<ProjectRole>("member");

  const handleClose = () => {
    onOpenChange(false);
    setTimeout(() => {
      setEmail("");
      setRole("member");
    }, 200);
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    const trimmed = email.trim();
    if (!trimmed) {
      toast.error("Please enter the user's email address");
      return;
    }
    try {
      await grant.mutateAsync({ userEmail: trimmed, role });
      toast.success(`Granted ${trimmed} the ${role} role`);
      handleClose();
    } catch (error) {
      toast.error(projectMemberErrorMessage(error, "Failed to add member"));
    }
  };

  return (
    <Dialog open={open} onOpenChange={handleClose}>
      <DialogContent className="bg-gray-800 border-gray-700 text-gray-100">
        <DialogHeader>
          <DialogTitle>Add project member</DialogTitle>
          <DialogDescription className="text-gray-400">
            Grant an existing user a role on this project.
          </DialogDescription>
        </DialogHeader>

        <form onSubmit={handleSubmit}>
          <div className="space-y-4 py-4">
            <div className="space-y-2">
              <Label htmlFor="pmEmail" className="text-gray-200">
                Email
              </Label>
              <Input
                id="pmEmail"
                type="email"
                placeholder="user@example.com"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                className="bg-gray-900 border-gray-700 text-gray-100"
                disabled={grant.isPending}
                autoFocus
              />
              <p className="text-xs text-gray-500">
                The user must already have a Strato account.
              </p>
            </div>

            <div className="space-y-2">
              <Label htmlFor="pmRole" className="text-gray-200">
                Role
              </Label>
              <Select
                value={role}
                onValueChange={(v) => setRole(v as ProjectRole)}
                disabled={grant.isPending}
              >
                <SelectTrigger
                  id="pmRole"
                  className="bg-gray-900 border-gray-700 text-gray-100"
                >
                  <SelectValue />
                </SelectTrigger>
                <SelectContent className="bg-gray-800 border-gray-700">
                  {ROLES.map((r) => (
                    <SelectItem
                      key={r.value}
                      value={r.value}
                      className="text-gray-100 focus:bg-gray-700 focus:text-gray-100"
                    >
                      {r.label} — <span className="text-gray-400">{r.hint}</span>
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
          </div>

          <DialogFooter>
            <Button
              type="button"
              variant="outline"
              className="border-gray-600"
              onClick={handleClose}
              disabled={grant.isPending}
            >
              Cancel
            </Button>
            <Button
              type="submit"
              className="bg-blue-600 hover:bg-blue-700"
              disabled={grant.isPending}
            >
              {grant.isPending ? (
                <>
                  <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                  Adding...
                </>
              ) : (
                "Add member"
              )}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
