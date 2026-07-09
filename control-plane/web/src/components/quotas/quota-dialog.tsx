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
  useCreateQuota,
  useUpdateQuota,
  quotaErrorMessage,
  type QuotaCreateTarget,
} from "@/lib/hooks";
import type { ResourceQuota } from "@/types/api";
import { toast } from "sonner";

interface QuotaDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  /** Present when creating a new quota. */
  target?: QuotaCreateTarget;
  /** Present when editing an existing quota. */
  quota?: ResourceQuota;
  /** Human-readable name of the entity the quota applies to. */
  scopeLabel: string;
  /** Environments available when creating a project-scoped quota. */
  environments?: string[];
}

type QuotaForm = {
  name: string;
  maxVCPUs: string;
  maxMemoryGB: string;
  maxStorageGB: string;
  maxVMs: string;
  maxNetworks: string;
  environment: string;
  isEnabled: boolean;
};

const emptyForm: QuotaForm = {
  name: "",
  maxVCPUs: "8",
  maxMemoryGB: "16",
  maxStorageGB: "100",
  maxVMs: "10",
  maxNetworks: "5",
  environment: "",
  isEnabled: true,
};

function formFromQuota(quota: ResourceQuota | undefined): QuotaForm {
  if (!quota) return emptyForm;
  return {
    name: quota.name,
    maxVCPUs: String(quota.limits.maxVCPUs),
    maxMemoryGB: String(quota.limits.maxMemoryGB),
    maxStorageGB: String(quota.limits.maxStorageGB),
    maxVMs: String(quota.limits.maxVMs),
    maxNetworks: String(quota.limits.maxNetworks),
    environment: quota.environment ?? "",
    isEnabled: quota.isEnabled,
  };
}

export function QuotaDialog({
  open,
  onOpenChange,
  target,
  quota,
  scopeLabel,
  environments,
}: QuotaDialogProps) {
  const isEdit = !!quota;
  // The form is seeded once from props; the parent remounts this dialog (via
  // `key`) whenever the target quota changes, so no syncing effect is needed.
  const [form, setForm] = useState<QuotaForm>(() => formFromQuota(quota));
  const createQuota = useCreateQuota();
  const updateQuota = useUpdateQuota();
  const isLoading = createQuota.isPending || updateQuota.isPending;

  const isProjectScope = target?.scope === "project";
  const showEnvironment =
    !isEdit && isProjectScope && (environments?.length ?? 0) > 0;

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!form.name.trim()) {
      toast.error("Please enter a quota name");
      return;
    }

    const numbers = {
      maxVCPUs: parseInt(form.maxVCPUs, 10),
      maxMemoryGB: parseFloat(form.maxMemoryGB),
      maxStorageGB: parseFloat(form.maxStorageGB),
      maxVMs: parseInt(form.maxVMs, 10),
      maxNetworks: parseInt(form.maxNetworks, 10),
    };

    if (
      Object.values(numbers).some((n) => Number.isNaN(n) || n < 0)
    ) {
      toast.error("All limits must be non-negative numbers");
      return;
    }

    try {
      if (isEdit && quota) {
        await updateQuota.mutateAsync({
          quotaId: quota.id,
          data: {
            name: form.name.trim(),
            ...numbers,
            isEnabled: form.isEnabled,
          },
        });
        toast.success(`Quota "${form.name}" updated`);
      } else if (target) {
        await createQuota.mutateAsync({
          target,
          data: {
            name: form.name.trim(),
            ...numbers,
            environment:
              showEnvironment && form.environment
                ? form.environment
                : undefined,
            isEnabled: form.isEnabled,
          },
        });
        toast.success(`Quota "${form.name}" created`);
      }
      onOpenChange(false);
    } catch (error) {
      toast.error(
        quotaErrorMessage(
          error,
          isEdit ? "Failed to update quota" : "Failed to create quota"
        )
      );
    }
  };

  const numberField = (
    key: keyof typeof emptyForm,
    label: string,
    step?: string
  ) => (
    <div className="space-y-2">
      <Label htmlFor={key} className="text-foreground">
        {label}
      </Label>
      <Input
        id={key}
        type="number"
        min="0"
        step={step}
        value={form[key] as string}
        onChange={(e) => setForm({ ...form, [key]: e.target.value })}
        className="bg-background border-border text-foreground"
        disabled={isLoading}
      />
    </div>
  );

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="bg-card border-border text-foreground">
        <DialogHeader>
          <DialogTitle>
            {isEdit ? "Edit Resource Quota" : "Create Resource Quota"}
          </DialogTitle>
          <DialogDescription className="text-muted-foreground">
            {isEdit ? "Update limits for" : "Set resource limits for"}{" "}
            <span className="text-foreground">{scopeLabel}</span>
          </DialogDescription>
        </DialogHeader>
        <form onSubmit={handleSubmit}>
          <div className="space-y-4 py-4">
            <div className="space-y-2">
              <Label htmlFor="name" className="text-foreground">
                Quota Name
              </Label>
              <Input
                id="name"
                placeholder="default"
                value={form.name}
                onChange={(e) => setForm({ ...form, name: e.target.value })}
                className="bg-background border-border text-foreground"
                disabled={isLoading}
              />
            </div>

            {showEnvironment && (
              <div className="space-y-2">
                <Label htmlFor="environment" className="text-foreground">
                  Environment (optional)
                </Label>
                <select
                  id="environment"
                  value={form.environment}
                  onChange={(e) =>
                    setForm({ ...form, environment: e.target.value })
                  }
                  disabled={isLoading}
                  className="w-full h-9 px-3 py-2 bg-background border border-border text-foreground rounded-md text-sm focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent disabled:opacity-50"
                >
                  <option value="">All environments</option>
                  {environments?.map((env) => (
                    <option key={env} value={env}>
                      {env}
                    </option>
                  ))}
                </select>
              </div>
            )}

            <div className="grid grid-cols-2 gap-4">
              {numberField("maxVCPUs", "Max vCPUs")}
              {numberField("maxVMs", "Max VMs")}
              {numberField("maxMemoryGB", "Max Memory (GB)", "0.5")}
              {numberField("maxStorageGB", "Max Storage (GB)", "0.5")}
              {numberField("maxNetworks", "Max Networks")}
            </div>

            <label className="flex items-center gap-2 text-sm text-foreground">
              <input
                type="checkbox"
                checked={form.isEnabled}
                onChange={(e) =>
                  setForm({ ...form, isEnabled: e.target.checked })
                }
                disabled={isLoading}
                className="h-4 w-4 rounded border-input bg-background accent-blue-600"
              />
              Enforce this quota
            </label>
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
                  {isEdit ? "Saving..." : "Creating..."}
                </>
              ) : isEdit ? (
                "Save Changes"
              ) : (
                "Create Quota"
              )}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
