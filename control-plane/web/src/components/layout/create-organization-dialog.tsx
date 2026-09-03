"use client";

import { DialogSubmitFooter } from "@/components/ui/dialog-submit-footer";

import { errorMessage } from "@/lib/errors";

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
import { organizationsApi } from "@/lib/api/organizations";
import { toast } from "sonner";

interface CreateOrganizationDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onCreated?: () => void;
}

export function CreateOrganizationDialog({
  open,
  onOpenChange,
  onCreated,
}: CreateOrganizationDialogProps) {
  const [isLoading, setIsLoading] = useState(false);
  const [formData, setFormData] = useState({
    name: "",
    description: "",
  });

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!formData.name.trim()) {
      toast.error("Please enter an organization name");
      return;
    }

    setIsLoading(true);
    try {
      await organizationsApi.create({
        name: formData.name,
        description: formData.description || undefined,
      });
      toast.success(`Organization "${formData.name}" created successfully`);
      onOpenChange(false);
      onCreated?.();
      setFormData({ name: "", description: "" });
    } catch (error) {
      toast.error(
        errorMessage(error, "Failed to create organization")
      );
    } finally {
      setIsLoading(false);
    }
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="bg-card border-border text-foreground">
        <DialogHeader>
          <DialogTitle>Create Organization</DialogTitle>
          <DialogDescription className="text-muted-foreground">
            Create a new organization to manage resources
          </DialogDescription>
        </DialogHeader>
        <form onSubmit={handleSubmit}>
          <div className="space-y-4 py-4">
            <div className="space-y-2">
              <Label htmlFor="org-name" className="text-foreground">
                Organization Name
              </Label>
              <Input
                id="org-name"
                placeholder="My Organization"
                value={formData.name}
                onChange={(e) =>
                  setFormData({ ...formData, name: e.target.value })
                }
                className="bg-background border-border text-foreground"
                disabled={isLoading}
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="org-description" className="text-foreground">
                Description
              </Label>
              <Input
                id="org-description"
                placeholder="Optional description"
                value={formData.description}
                onChange={(e) =>
                  setFormData({ ...formData, description: e.target.value })
                }
                className="bg-background border-border text-foreground"
                disabled={isLoading}
              />
            </div>
          </div>
          <DialogSubmitFooter
            submitLabel="Create Organization"
            pendingLabel="Creating..."
            isPending={isLoading}
            onCancel={() => onOpenChange(false)}
          />
        </form>
      </DialogContent>
    </Dialog>
  );
}
