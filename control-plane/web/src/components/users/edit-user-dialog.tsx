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
import { useUpdateUser, userErrorMessage } from "@/lib/hooks/use-users";
import { toast } from "sonner";
import type { User } from "@/types/api";

interface EditUserDialogProps {
  user: User;
  open: boolean;
  onOpenChange: (open: boolean) => void;
}

export function EditUserDialog({
  user,
  open,
  onOpenChange,
}: EditUserDialogProps) {
  // Parents mount this dialog only while it is open, so state re-initializes
  // from the latest user data on every open.
  const [displayName, setDisplayName] = useState(user.displayName);
  const [email, setEmail] = useState(user.email);

  const updateUser = useUpdateUser();

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!displayName.trim()) {
      toast.error("Display name is required");
      return;
    }
    if (!email.trim()) {
      toast.error("Email is required");
      return;
    }

    try {
      await updateUser.mutateAsync({
        id: user.id,
        data: { displayName: displayName.trim(), email: email.trim() },
      });
      toast.success(`User "${user.username}" updated`);
      onOpenChange(false);
    } catch (error) {
      toast.error(userErrorMessage(error, "Failed to update user"));
    }
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="bg-card border-border text-foreground">
        <DialogHeader>
          <DialogTitle>Edit {user.username}</DialogTitle>
          <DialogDescription className="text-muted-foreground">
            Update the user&apos;s display name and email address.
          </DialogDescription>
        </DialogHeader>

        <form onSubmit={handleSubmit} className="space-y-4">
          <div className="space-y-2">
            <Label className="text-foreground">Username</Label>
            <Input
              value={user.username}
              className="bg-muted/50 text-muted-foreground"
              disabled
            />
          </div>

          <div className="space-y-2">
            <Label htmlFor="edit-user-display-name" className="text-foreground">
              Display Name
            </Label>
            <Input
              id="edit-user-display-name"
              value={displayName}
              onChange={(e) => setDisplayName(e.target.value)}
              className="bg-background border-border text-foreground"
              disabled={updateUser.isPending}
            />
          </div>

          <div className="space-y-2">
            <Label htmlFor="edit-user-email" className="text-foreground">
              Email
            </Label>
            <Input
              id="edit-user-email"
              type="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              className="bg-background border-border text-foreground"
              disabled={updateUser.isPending}
            />
          </div>

          <DialogFooter>
            <Button
              type="button"
              variant="outline"
              className="border-input"
              onClick={() => onOpenChange(false)}
              disabled={updateUser.isPending}
            >
              Cancel
            </Button>
            <Button
              type="submit"
              className="bg-primary hover:bg-primary/90"
              disabled={updateUser.isPending}
            >
              {updateUser.isPending ? (
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
      </DialogContent>
    </Dialog>
  );
}
