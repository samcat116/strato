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
import { securityGroupsApi } from "@/lib/api/security-groups";
import { useProjectContext } from "@/providers";
import { toast } from "sonner";

interface CreateSecurityGroupDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onCreated?: () => void;
}

export function CreateSecurityGroupDialog({
  open,
  onOpenChange,
  onCreated,
}: CreateSecurityGroupDialogProps) {
  const [isLoading, setIsLoading] = useState(false);
  const [formData, setFormData] = useState({ name: "", description: "" });

  // The group is created in the project selected in the header switcher.
  const { currentProject } = useProjectContext();
  const projectId = currentProject?.id;

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    const name = formData.name.trim();
    if (!name) {
      toast.error("Please enter a security group name");
      return;
    }

    setIsLoading(true);
    try {
      await securityGroupsApi.create({
        name,
        description: formData.description.trim() || undefined,
        projectId,
      });
      toast.success(`Security group "${name}" created`);
      onOpenChange(false);
      onCreated?.();
      setFormData({ name: "", description: "" });
    } catch (error) {
      toast.error(
        error instanceof Error
          ? error.message
          : "Failed to create security group"
      );
    } finally {
      setIsLoading(false);
    }
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="bg-card border-border text-foreground">
        <DialogHeader>
          <DialogTitle>Create Security Group</DialogTitle>
          <DialogDescription className="text-muted-foreground">
            {currentProject
              ? `Create a new security group in ${currentProject.name}`
              : "Create a new security group"}
          </DialogDescription>
        </DialogHeader>
        <form onSubmit={handleSubmit}>
          <div className="space-y-4 py-4">
            <div className="space-y-2">
              <Label htmlFor="securityGroupName" className="text-foreground">
                Name
              </Label>
              <Input
                id="securityGroupName"
                placeholder="web-servers"
                value={formData.name}
                onChange={(e) =>
                  setFormData({ ...formData, name: e.target.value })
                }
                className="bg-background border-border text-foreground"
                disabled={isLoading}
                autoFocus
              />
            </div>
            <div className="space-y-2">
              <Label
                htmlFor="securityGroupDescription"
                className="text-foreground"
              >
                Description (optional)
              </Label>
              <Input
                id="securityGroupDescription"
                placeholder="Allow HTTP/HTTPS from anywhere"
                value={formData.description}
                onChange={(e) =>
                  setFormData({ ...formData, description: e.target.value })
                }
                className="bg-background border-border text-foreground"
                disabled={isLoading}
              />
              <p className="text-xs text-muted-foreground">
                A new group starts with no rules, so it allows no traffic until
                you add some.
              </p>
            </div>
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
                  Creating...
                </>
              ) : (
                "Create Security Group"
              )}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
