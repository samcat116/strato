"use client";

import { useEffect, useMemo, useRef, useState } from "react";
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
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { iamApi } from "@/lib/api/iam";
import {
  useActionCatalog,
  useCreateRole,
  useUpdateRole,
  useValidateRole,
  iamErrorMessage,
} from "@/lib/hooks";
import { toast } from "sonner";
import type { IAMRole, IAMRoleOwnerType } from "@/types/api";

interface RoleFormDialogProps {
  ownerType: IAMRoleOwnerType;
  ownerId: string;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  /** When provided, edits (or, if managed, views) this role. */
  role?: IAMRole | null;
}

export function RoleFormDialog({
  ownerType,
  ownerId,
  open,
  onOpenChange,
  role,
}: RoleFormDialogProps) {
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="bg-card border-border text-foreground sm:max-w-2xl">
        {/* Keyed so all state resets when the target role (or create vs. edit)
            changes. */}
        <RoleForm
          key={role?.id ?? "new"}
          ownerType={ownerType}
          ownerId={ownerId}
          role={role ?? null}
          onClose={() => onOpenChange(false)}
        />
      </DialogContent>
    </Dialog>
  );
}

function RoleForm({
  ownerType,
  ownerId,
  role,
  onClose,
}: {
  ownerType: IAMRoleOwnerType;
  ownerId: string;
  role: IAMRole | null;
  onClose: () => void;
}) {
  const isEdit = !!role;
  const readOnly = !!role?.managed;

  const createRole = useCreateRole(ownerType, ownerId);
  const updateRole = useUpdateRole(ownerType, ownerId);
  const validateRole = useValidateRole();
  const isPending = createRole.isPending || updateRole.isPending;

  const { data: services = [], isLoading: catalogLoading } = useActionCatalog();

  const [name, setName] = useState(role?.name ?? "");
  const [description, setDescription] = useState(role?.description ?? "");
  const [tab, setTab] = useState<"actions" | "cedar">("actions");

  const [selectedActions, setSelectedActions] = useState<Set<string>>(
    () => new Set(role?.actions ?? [])
  );

  // Cedar preview state (generated from the selected actions).
  const [preview, setPreview] = useState(role?.cedarText ?? "");
  const [previewError, setPreviewError] = useState<string | null>(null);
  // The id the generated/edited Cedar text is conditioned on. For an edit it is
  // the role's own id; for a create the validate round-trip hands one out.
  const allocatedIdRef = useRef<string | null>(role?.id ?? null);

  // Advanced mode: the raw Cedar textarea is the source of truth on submit.
  const [advanced, setAdvanced] = useState(false);
  const [cedarText, setCedarText] = useState(role?.cedarText ?? "");
  const [cedarActions, setCedarActions] = useState<string[] | null>(null);
  const [cedarError, setCedarError] = useState<string | null>(null);

  const actionsKey = useMemo(
    () => [...selectedActions].sort().join(","),
    [selectedActions]
  );

  // Regenerate the read-only preview whenever the Cedar tab is showing it and
  // the selected actions change. Advanced mode owns the textarea, so it opts
  // out. Managed roles never regenerate — they only display their stored text.
  useEffect(() => {
    if (readOnly || advanced || tab !== "cedar") return;
    if (selectedActions.size === 0) {
      setPreview("");
      setPreviewError(null);
      return;
    }
    let cancelled = false;
    iamApi
      .validateRole({
        actions: [...selectedActions],
        id: allocatedIdRef.current ?? undefined,
      })
      .then((res) => {
        if (cancelled) return;
        setPreview(res.cedarText);
        setPreviewError(null);
        allocatedIdRef.current = res.id;
      })
      .catch((error) => {
        if (cancelled) return;
        setPreviewError(iamErrorMessage(error, "Could not generate preview"));
      });
    return () => {
      cancelled = true;
    };
    // actionsKey stands in for the set contents.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [tab, advanced, actionsKey, readOnly]);

  const toggleAction = (action: string) => {
    setSelectedActions((prev) => {
      const next = new Set(prev);
      if (next.has(action)) next.delete(action);
      else next.add(action);
      return next;
    });
  };

  const toggleService = (serviceActions: string[], allSelected: boolean) => {
    setSelectedActions((prev) => {
      const next = new Set(prev);
      for (const a of serviceActions) {
        if (allSelected) next.delete(a);
        else next.add(a);
      }
      return next;
    });
  };

  const enableAdvanced = async () => {
    // Seed the editor from the generated permit so the user has a valid,
    // correctly-id'd starting point. Needs at least one action to generate.
    if (selectedActions.size === 0) {
      toast.error(
        "Select at least one action first — it seeds the Cedar you can then refine."
      );
      return;
    }
    try {
      const res = await validateRole.mutateAsync({
        actions: [...selectedActions],
        id: allocatedIdRef.current ?? undefined,
      });
      allocatedIdRef.current = res.id;
      setCedarText(res.cedarText);
      setCedarActions(res.actions);
      setCedarError(null);
      setAdvanced(true);
      setTab("cedar");
    } catch (error) {
      toast.error(iamErrorMessage(error, "Could not prepare the editor"));
    }
  };

  const handleValidate = async () => {
    try {
      const res = await validateRole.mutateAsync({
        cedarText,
        id: allocatedIdRef.current ?? undefined,
      });
      allocatedIdRef.current = res.id;
      setCedarActions(res.actions);
      setCedarError(null);
      toast.success(`Valid — grants ${res.actions.length} action(s)`);
    } catch (error) {
      setCedarActions(null);
      setCedarError(iamErrorMessage(error, "Cedar validation failed"));
    }
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (readOnly) {
      onClose();
      return;
    }

    const trimmedName = name.trim();
    if (!trimmedName) {
      toast.error("Role name is required");
      return;
    }
    if (!advanced && selectedActions.size === 0) {
      toast.error("Select at least one action, or edit the policy as Cedar.");
      return;
    }

    try {
      if (isEdit && role) {
        await updateRole.mutateAsync({
          roleId: role.id,
          data: advanced
            ? { name: trimmedName, description: description.trim(), cedarText }
            : {
                name: trimmedName,
                description: description.trim(),
                actions: [...selectedActions],
              },
        });
        toast.success(`Updated ${trimmedName}`);
      } else {
        await createRole.mutateAsync(
          advanced
            ? {
                name: trimmedName,
                description: description.trim() || undefined,
                ownerType,
                ownerId,
                cedarText,
                id: allocatedIdRef.current ?? undefined,
              }
            : {
                name: trimmedName,
                description: description.trim() || undefined,
                ownerType,
                ownerId,
                actions: [...selectedActions],
              }
        );
        toast.success(`Created ${trimmedName}`);
      }
      onClose();
    } catch (error) {
      toast.error(
        iamErrorMessage(
          error,
          isEdit ? "Failed to update role" : "Failed to create role"
        )
      );
    }
  };

  return (
    <>
      <DialogHeader>
        <DialogTitle>
          {readOnly ? "View role" : isEdit ? "Edit role" : "Create role"}
        </DialogTitle>
        <DialogDescription className="text-muted-foreground">
          {readOnly
            ? "This is a seeded default role and can't be changed."
            : "Pick the actions this role grants, then optionally refine the generated Cedar policy directly."}
        </DialogDescription>
      </DialogHeader>

      <form onSubmit={handleSubmit}>
        <div className="space-y-4 py-4">
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <div className="space-y-2">
              <Label htmlFor="roleName" className="text-foreground">
                Name
              </Label>
              <Input
                id="roleName"
                value={name}
                onChange={(e) => setName(e.target.value)}
                placeholder="staging-deployer"
                className="bg-background border-border text-foreground"
                disabled={isPending || readOnly}
                autoFocus={!readOnly}
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="roleDescription" className="text-foreground">
                Description
              </Label>
              <Input
                id="roleDescription"
                value={description}
                onChange={(e) => setDescription(e.target.value)}
                placeholder="Optional"
                className="bg-background border-border text-foreground"
                disabled={isPending || readOnly}
              />
            </div>
          </div>

          <Tabs
            value={tab}
            onValueChange={(v) => setTab(v as "actions" | "cedar")}
          >
            <TabsList className="bg-background">
              <TabsTrigger
                value="actions"
                className="data-[state=active]:bg-muted"
              >
                Actions
              </TabsTrigger>
              <TabsTrigger
                value="cedar"
                className="data-[state=active]:bg-muted"
              >
                Cedar
              </TabsTrigger>
            </TabsList>

            {/* Action picker */}
            <TabsContent value="actions" className="mt-3">
              {advanced && (
                <p className="text-xs text-amber-600 dark:text-amber-400 mb-3">
                  You&apos;re editing raw Cedar. The action picker is disabled;
                  turn off advanced editing on the Cedar tab to use it.
                </p>
              )}
              {catalogLoading ? (
                <p className="text-sm text-muted-foreground py-4">
                  Loading actions…
                </p>
              ) : (
                <div className="max-h-72 overflow-y-auto space-y-4 pr-1">
                  {services.map((svc) => {
                    const acts = svc.actions.map((a) => a.action);
                    const selectedCount = acts.filter((a) =>
                      selectedActions.has(a)
                    ).length;
                    const allSelected =
                      acts.length > 0 && selectedCount === acts.length;
                    return (
                      <div key={svc.service} className="space-y-1.5">
                        <label className="flex items-center gap-2 text-sm font-medium text-foreground">
                          <input
                            type="checkbox"
                            checked={allSelected}
                            ref={(el) => {
                              if (el)
                                el.indeterminate =
                                  selectedCount > 0 && !allSelected;
                            }}
                            onChange={() => toggleService(acts, allSelected)}
                            disabled={advanced}
                            className="h-4 w-4 rounded border-input bg-background accent-blue-600"
                          />
                          {svc.service}
                          <span className="text-xs text-muted-foreground font-normal">
                            ({selectedCount}/{acts.length})
                          </span>
                        </label>
                        <div className="grid grid-cols-1 sm:grid-cols-2 gap-x-4 gap-y-1 pl-6">
                          {svc.actions.map((a) => (
                            <label
                              key={a.action}
                              className="flex items-center gap-2 text-sm text-muted-foreground"
                            >
                              <input
                                type="checkbox"
                                checked={selectedActions.has(a.action)}
                                onChange={() => toggleAction(a.action)}
                                disabled={advanced}
                                className="h-4 w-4 rounded border-input bg-background accent-blue-600"
                              />
                              <span className="font-mono text-xs text-foreground/90">
                                {a.action}
                              </span>
                            </label>
                          ))}
                        </div>
                      </div>
                    );
                  })}
                </div>
              )}
              <p className="text-xs text-muted-foreground mt-3">
                {selectedActions.size} action(s) selected.
              </p>
            </TabsContent>

            {/* Cedar preview / advanced editor */}
            <TabsContent value="cedar" className="mt-3 space-y-2">
              {readOnly ? (
                <textarea
                  value={role?.cedarText ?? ""}
                  readOnly
                  rows={10}
                  spellCheck={false}
                  className="w-full px-3 py-2 bg-muted/40 border border-border text-foreground rounded-md font-mono text-xs resize-y"
                />
              ) : advanced ? (
                <>
                  <textarea
                    value={cedarText}
                    onChange={(e) => {
                      setCedarText(e.target.value);
                      setCedarActions(null);
                      setCedarError(null);
                    }}
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
                      disabled={validateRole.isPending || !cedarText.trim()}
                    >
                      {validateRole.isPending ? (
                        <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                      ) : null}
                      Validate
                    </Button>
                    <Button
                      type="button"
                      size="sm"
                      variant="ghost"
                      className="text-muted-foreground"
                      onClick={() => setAdvanced(false)}
                      disabled={isPending}
                    >
                      Back to action picker
                    </Button>
                  </div>
                  {cedarActions && (
                    <p className="flex items-center gap-1.5 text-xs text-green-600 dark:text-green-400">
                      <CheckCircle2 className="h-3.5 w-3.5" />
                      Valid — grants {cedarActions.length} action(s):{" "}
                      <span className="font-mono">
                        {cedarActions.join(", ")}
                      </span>
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
                </>
              ) : (
                <>
                  <p className="text-xs text-muted-foreground">
                    Generated from the selected actions. Edit it directly to add
                    conditions an action list can&apos;t express (for example{" "}
                    <span className="font-mono">
                      resource.environment == &quot;staging&quot;
                    </span>
                    ).
                  </p>
                  <textarea
                    value={
                      preview ||
                      "Select actions to generate a Cedar policy preview."
                    }
                    readOnly
                    rows={10}
                    spellCheck={false}
                    className="w-full px-3 py-2 bg-muted/40 border border-border text-foreground rounded-md font-mono text-xs resize-y"
                  />
                  {previewError && (
                    <p className="flex items-start gap-1.5 text-xs text-red-600 dark:text-red-400">
                      <XCircle className="h-3.5 w-3.5 mt-0.5 shrink-0" />
                      {previewError}
                    </p>
                  )}
                  <Button
                    type="button"
                    size="sm"
                    variant="outline"
                    className="border-input"
                    onClick={enableAdvanced}
                    disabled={validateRole.isPending || selectedActions.size === 0}
                  >
                    {validateRole.isPending ? (
                      <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                    ) : null}
                    Edit as Cedar
                  </Button>
                </>
              )}
            </TabsContent>
          </Tabs>
        </div>

        <DialogFooter>
          <Button
            type="button"
            variant="outline"
            className="border-input"
            onClick={onClose}
            disabled={isPending}
          >
            {readOnly ? "Close" : "Cancel"}
          </Button>
          {!readOnly && (
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
                "Create role"
              )}
            </Button>
          )}
        </DialogFooter>
      </form>
    </>
  );
}
