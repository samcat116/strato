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
import { useAddMember, memberErrorMessage } from "@/lib/hooks";
import { toast } from "sonner";

interface AddMemberDialogProps {
  orgId: string;
  open: boolean;
  onOpenChange: (open: boolean) => void;
}

export function AddMemberDialog({
  orgId,
  open,
  onOpenChange,
}: AddMemberDialogProps) {
  const addMember = useAddMember(orgId);
  const [email, setEmail] = useState("");
  const [role, setRole] = useState("member");

  const handleClose = () => {
    onOpenChange(false);
    // Reset state after close animation
    setTimeout(() => {
      setEmail("");
      setRole("member");
    }, 200);
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    const trimmed = email.trim();
    if (!trimmed) {
      toast.error("Please enter the member's email address");
      return;
    }

    try {
      await addMember.mutateAsync({ userEmail: trimmed, role });
      toast.success(`Added ${trimmed} to the organization`);
      handleClose();
    } catch (error) {
      toast.error(memberErrorMessage(error, "Failed to add member"));
    }
  };

  return (
    <Dialog open={open} onOpenChange={handleClose}>
      <DialogContent className="bg-card border-border text-foreground">
        <DialogHeader>
          <DialogTitle>Add Member</DialogTitle>
          <DialogDescription className="text-muted-foreground">
            Add an existing user to this organization by their email address.
          </DialogDescription>
        </DialogHeader>

        <form onSubmit={handleSubmit}>
          <div className="space-y-4 py-4">
            <div className="space-y-2">
              <Label htmlFor="memberEmail" className="text-foreground">
                Email
              </Label>
              <Input
                id="memberEmail"
                type="email"
                placeholder="user@example.com"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                className="bg-background border-border text-foreground"
                disabled={addMember.isPending}
                autoFocus
              />
              <p className="text-xs text-muted-foreground">
                The user must already have a Strato account.
              </p>
            </div>

            <div className="space-y-2">
              <Label htmlFor="memberRole" className="text-foreground">
                Role
              </Label>
              <Select
                value={role}
                onValueChange={setRole}
                disabled={addMember.isPending}
              >
                <SelectTrigger
                  id="memberRole"
                  className="bg-background border-border text-foreground"
                >
                  <SelectValue />
                </SelectTrigger>
                <SelectContent className="bg-card border-border">
                  <SelectItem
                    value="member"
                    className="text-foreground focus:bg-accent focus:text-accent-foreground"
                  >
                    Member
                  </SelectItem>
                  <SelectItem
                    value="admin"
                    className="text-foreground focus:bg-accent focus:text-accent-foreground"
                  >
                    Admin
                  </SelectItem>
                </SelectContent>
              </Select>
            </div>
          </div>

          <DialogFooter>
            <Button
              type="button"
              variant="outline"
              className="border-input"
              onClick={handleClose}
              disabled={addMember.isPending}
            >
              Cancel
            </Button>
            <Button
              type="submit"
              className="bg-primary hover:bg-primary/90"
              disabled={addMember.isPending}
            >
              {addMember.isPending ? (
                <>
                  <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                  Adding...
                </>
              ) : (
                "Add Member"
              )}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
