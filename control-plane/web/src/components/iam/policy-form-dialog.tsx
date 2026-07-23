"use client";

import { useState } from "react";
import { Loader2, CheckCircle2, XCircle } from "lucide-react";
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
import { Badge } from "@/components/ui/badge";
import {
  useCreatePolicy,
  useUpdatePolicy,
  useValidatePolicy,
  iamErrorMessage,
} from "@/lib/hooks";
import { toast } from "sonner";
import type {
  IAMPolicy,
  IAMPolicyEffect,
  IAMRoleOwnerType,
} from "@/types/api";

interface PolicyFormDialogProps {
  ownerType: IAMRoleOwnerType;
  ownerId: string;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  /** When provided, edits this policy instead of creating one. */
  policy?: IAMPolicy | null;
}

const SAMPLE = `forbid(
  principal,
  action in [Action::"vm:delete"],
  resource
)
when { resource.environment == "production" };`;

export function PolicyFormDialog({
  ownerType,
  ownerId,
  open,
  onOpenChange,
  policy,
}: PolicyFormDialogProps) {
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="bg-card border-border text-foreground sm:max-w-2xl">
        <PolicyForm
          key={policy?.id ?? "new"}
          ownerType={ownerType}
          ownerId={ownerId}
          policy={policy ?? null}
          onClose={() => onOpenChange(false)}
        />
      </DialogContent>
    </Dialog>
  );
}

function PolicyForm({
  ownerType,
  ownerId,
  policy,
  onClose,
}: {
  ownerType: IAMRoleOwnerType;
  ownerId: string;
  policy: IAMPolicy | null;
  onClose: () => void;
}) {
  const isEdit = !!policy;
  const createPolicy = useCreatePolicy(ownerType, ownerId);
  const updatePolicy = useUpdatePolicy(ownerType, ownerId);
  const validatePolicy = useValidatePolicy();
  const isPending = createPolicy.isPending || updatePolicy.isPending;

  const [name, setName] = useState(policy?.name ?? "");
  const [description, setDescription] = useState(policy?.description ?? "");
  const [cedarText, setCedarText] = useState(policy?.cedarText ?? "");
  const [enabled, setEnabled] = useState(policy?.enabled ?? true);

  const [validEffect, setValidEffect] = useState<IAMPolicyEffect | null>(
    policy?.effect ?? null
  );
  const [cedarError, setCedarError] = useState<string | null>(null);

  const handleValidate = async () => {
    try {
      const res = await validatePolicy.mutateAsync({
        ownerType,
        ownerId,
        cedarText,
        id: policy?.id,
      });
      setValidEffect(res.effect);
      setCedarError(null);
      toast.success(`Valid ${res.effect} policy`);
    } catch (error) {
      setValidEffect(null);
      setCedarError(iamErrorMessage(error, "Cedar validation failed"));
    }
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    const trimmedName = name.trim();
    if (!trimmedName) {
      toast.error("Policy name is required");
      return;
    }
    if (!cedarText.trim()) {
      toast.error("The Cedar policy can't be empty");
      return;
    }

    try {
      if (isEdit && policy) {
        await updatePolicy.mutateAsync({
          policyId: policy.id,
          data: {
            name: trimmedName,
            description: description.trim(),
            cedarText,
            enabled,
          },
        });
        toast.success(`Updated ${trimmedName}`);
      } else {
        await createPolicy.mutateAsync({
          name: trimmedName,
          description: description.trim() || undefined,
          ownerType,
          ownerId,
          cedarText,
          enabled,
        });
        toast.success(`Created ${trimmedName}`);
      }
      onClose();
    } catch (error) {
      toast.error(
        iamErrorMessage(
          error,
          isEdit ? "Failed to update policy" : "Failed to create policy"
        )
      );
    }
  };

  return (
    <>
      <DialogHeader>
        <DialogTitle>
          {isEdit ? "Edit policy" : "Create policy"}
        </DialogTitle>
        <DialogDescription className="text-muted-foreground">
          Authored Cedar policies are compiled into the policy set alongside
          role permits. A permit widens access; a forbid ceilings it — even over
          a role grant. The effect is read from the text.
        </DialogDescription>
      </DialogHeader>

      <form onSubmit={handleSubmit}>
        <div className="space-y-4 py-4">
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <div className="space-y-2">
              <Label htmlFor="policyName" className="text-foreground">
                Name
              </Label>
              <Input
                id="policyName"
                value={name}
                onChange={(e) => setName(e.target.value)}
                placeholder="no-prod-deletes"
                className="bg-background border-border text-foreground"
                disabled={isPending}
                autoFocus
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="policyDescription" className="text-foreground">
                Description
              </Label>
              <Input
                id="policyDescription"
                value={description}
                onChange={(e) => setDescription(e.target.value)}
                placeholder="Optional"
                className="bg-background border-border text-foreground"
                disabled={isPending}
              />
            </div>
          </div>

          <div className="space-y-2">
            <div className="flex items-center justify-between">
              <Label htmlFor="policyCedar" className="text-foreground">
                Cedar policy
              </Label>
              {validEffect && (
                <Badge
                  variant="outline"
                  className={
                    validEffect === "forbid"
                      ? "border-red-500/60 bg-red-500/10 text-red-600 dark:text-red-400"
                      : "border-green-500/60 bg-green-500/10 text-green-600 dark:text-green-400"
                  }
                >
                  {validEffect === "forbid" ? "Forbid" : "Permit"}
                </Badge>
              )}
            </div>
            <textarea
              id="policyCedar"
              value={cedarText}
              onChange={(e) => {
                setCedarText(e.target.value);
                setValidEffect(null);
                setCedarError(null);
              }}
              placeholder={SAMPLE}
              rows={10}
              spellCheck={false}
              disabled={isPending}
              className="w-full px-3 py-2 bg-background border border-border text-foreground rounded-md font-mono text-xs focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent resize-y"
            />
            <div className="flex items-center gap-3">
              <Button
                type="button"
                size="sm"
                variant="outline"
                className="border-input"
                onClick={handleValidate}
                disabled={validatePolicy.isPending || !cedarText.trim()}
              >
                {validatePolicy.isPending ? (
                  <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                ) : null}
                Validate
              </Button>
              <label className="flex items-center gap-2 text-sm text-foreground">
                <input
                  type="checkbox"
                  checked={enabled}
                  onChange={(e) => setEnabled(e.target.checked)}
                  disabled={isPending}
                  className="h-4 w-4 rounded border-input bg-background accent-blue-600"
                />
                Enabled
              </label>
            </div>
            {validEffect && !cedarError && (
              <p className="flex items-center gap-1.5 text-xs text-green-600 dark:text-green-400">
                <CheckCircle2 className="h-3.5 w-3.5" />
                Valid {validEffect} policy.
              </p>
            )}
            {cedarError && (
              <p className="flex items-start gap-1.5 text-xs text-red-600 dark:text-red-400">
                <XCircle className="h-3.5 w-3.5 mt-0.5 shrink-0" />
                <span className="font-mono whitespace-pre-wrap">
                  {cedarError}
                </span>
              </p>
            )}
          </div>
        </div>

        <DialogFooter>
          <Button
            type="button"
            variant="outline"
            className="border-input"
            onClick={onClose}
            disabled={isPending}
          >
            Cancel
          </Button>
          <Button
            type="submit"
            className="bg-primary hover:bg-primary/90"
            disabled={isPending}
          >
            {isPending ? (
              <>
                <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                {isEdit ? "Saving…" : "Creating…"}
              </>
            ) : isEdit ? (
              "Save changes"
            ) : (
              "Create policy"
            )}
          </Button>
        </DialogFooter>
      </form>
    </>
  );
}
