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
      <DialogContent className="bg-gray-800 border-gray-700 text-gray-100">
        <DialogHeader>
          <DialogTitle>Add Member</DialogTitle>
          <DialogDescription className="text-gray-400">
            Add an existing user to this organization by their email address.
          </DialogDescription>
        </DialogHeader>

        <form onSubmit={handleSubmit}>
          <div className="space-y-4 py-4">
            <div className="space-y-2">
              <Label htmlFor="memberEmail" className="text-gray-200">
                Email
              </Label>
              <Input
                id="memberEmail"
                type="email"
                placeholder="user@example.com"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                className="bg-gray-900 border-gray-700 text-gray-100"
                disabled={addMember.isPending}
                autoFocus
              />
              <p className="text-xs text-gray-500">
                The user must already have a Strato account.
              </p>
            </div>

            <div className="space-y-2">
              <Label htmlFor="memberRole" className="text-gray-200">
                Role
              </Label>
              <Select
                value={role}
                onValueChange={setRole}
                disabled={addMember.isPending}
              >
                <SelectTrigger
                  id="memberRole"
                  className="bg-gray-900 border-gray-700 text-gray-100"
                >
                  <SelectValue />
                </SelectTrigger>
                <SelectContent className="bg-gray-800 border-gray-700">
                  <SelectItem
                    value="member"
                    className="text-gray-100 focus:bg-gray-700 focus:text-gray-100"
                  >
                    Member
                  </SelectItem>
                  <SelectItem
                    value="admin"
                    className="text-gray-100 focus:bg-gray-700 focus:text-gray-100"
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
              className="border-gray-600"
              onClick={handleClose}
              disabled={addMember.isPending}
            >
              Cancel
            </Button>
            <Button
              type="submit"
              className="bg-blue-600 hover:bg-blue-700"
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
