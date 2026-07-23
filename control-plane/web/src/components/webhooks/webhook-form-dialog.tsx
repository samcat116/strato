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
import {
  useCreateWebhook,
  useUpdateWebhook,
  webhookErrorMessage,
} from "@/lib/hooks/use-webhooks";
import { WEBHOOK_EVENT_TYPES } from "./event-catalog";
import { toast } from "sonner";
import type { Project } from "@/lib/api/projects";
import type { WebhookSubscription, WebhookWithSecret } from "@/types/api";

const ORG_SCOPE = "__organization__";

interface WebhookFormDialogProps {
  orgId: string;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  /** When set, the dialog edits this subscription instead of creating one. */
  webhook?: WebhookSubscription | null;
  /** Org projects offered as an optional scope on create. */
  projects: Project[];
  /** Called with the one-time signing secret after a successful create. */
  onCreated: (result: WebhookWithSecret) => void;
}

export function WebhookFormDialog({
  orgId,
  open,
  onOpenChange,
  webhook,
  projects,
  onCreated,
}: WebhookFormDialogProps) {
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="bg-card border-border text-foreground max-h-[85vh] overflow-y-auto">
        {/* Radix unmounts the content when closed, so the form below mounts
            fresh on every open and its useState initializers do the prefill. */}
        <WebhookForm
          key={webhook?.id ?? "create"}
          orgId={orgId}
          webhook={webhook}
          projects={projects}
          onOpenChange={onOpenChange}
          onCreated={onCreated}
        />
      </DialogContent>
    </Dialog>
  );
}

function WebhookForm({
  orgId,
  webhook,
  projects,
  onOpenChange,
  onCreated,
}: {
  orgId: string;
  webhook?: WebhookSubscription | null;
  projects: Project[];
  onOpenChange: (open: boolean) => void;
  onCreated: (result: WebhookWithSecret) => void;
}) {
  const isEdit = !!webhook;
  const createWebhook = useCreateWebhook(orgId);
  const updateWebhook = useUpdateWebhook(orgId);
  const isPending = createWebhook.isPending || updateWebhook.isPending;

  const [name, setName] = useState(webhook?.name ?? "");
  const [url, setUrl] = useState(webhook?.url ?? "");
  const [projectId, setProjectId] = useState<string>(
    webhook?.projectId ?? ORG_SCOPE
  );
  const [isActive, setIsActive] = useState(webhook?.isActive ?? true);
  const [selectedEvents, setSelectedEvents] = useState<Set<string>>(
    () => new Set(webhook?.eventTypes ?? [])
  );

  const scopedProject = webhook?.projectId
    ? projects.find((p) => p.id === webhook.projectId)
    : null;

  const toggleEvent = (type: string) => {
    setSelectedEvents((prev) => {
      const next = new Set(prev);
      if (next.has(type)) next.delete(type);
      else next.add(type);
      return next;
    });
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    const trimmedName = name.trim();
    const trimmedUrl = url.trim();
    if (!trimmedName) {
      toast.error("Please enter a name for the webhook");
      return;
    }
    if (!trimmedUrl) {
      toast.error("Please enter the endpoint URL");
      return;
    }

    const eventTypes = WEBHOOK_EVENT_TYPES.map((e) => e.type).filter((t) =>
      selectedEvents.has(t)
    );

    try {
      if (isEdit && webhook) {
        await updateWebhook.mutateAsync({
          webhookId: webhook.id,
          data: {
            name: trimmedName,
            url: trimmedUrl,
            eventTypes,
            isActive,
          },
        });
        toast.success(`Webhook "${trimmedName}" updated`);
        onOpenChange(false);
      } else {
        const result = await createWebhook.mutateAsync({
          name: trimmedName,
          url: trimmedUrl,
          projectId: projectId === ORG_SCOPE ? undefined : projectId,
          eventTypes: eventTypes.length > 0 ? eventTypes : undefined,
        });
        toast.success(`Webhook "${trimmedName}" created`);
        onOpenChange(false);
        // Hand the one-time signing secret to the parent for display.
        onCreated(result);
      }
    } catch (error) {
      toast.error(
        webhookErrorMessage(
          error,
          isEdit ? "Failed to update webhook" : "Failed to create webhook"
        )
      );
    }
  };

  return (
    <>
      <DialogHeader>
        <DialogTitle>
          {isEdit ? `Edit ${webhook?.name}` : "Create Webhook"}
        </DialogTitle>
        <DialogDescription className="text-muted-foreground">
          {isEdit
            ? "Update the endpoint configuration for this webhook"
            : "Receive signed HTTP POST notifications when events happen in this organization"}
        </DialogDescription>
      </DialogHeader>

      <form onSubmit={handleSubmit}>
        <div className="space-y-4 py-4">
          <div className="space-y-2">
            <Label htmlFor="webhookName" className="text-foreground">
              Name
            </Label>
            <Input
              id="webhookName"
              placeholder="e.g. Ops Slack notifier"
              value={name}
              onChange={(e) => setName(e.target.value)}
              className="bg-background border-border text-foreground"
              disabled={isPending}
              autoFocus
            />
          </div>

          <div className="space-y-2">
            <Label htmlFor="webhookUrl" className="text-foreground">
              Endpoint URL
            </Label>
            <Input
              id="webhookUrl"
              placeholder="https://example.com/hooks/strato"
              value={url}
              onChange={(e) => setUrl(e.target.value)}
              className="bg-background border-border text-foreground font-mono"
              disabled={isPending}
            />
            <p className="text-xs text-muted-foreground">
              Events are POSTed to this URL as JSON, signed with the
              webhook&apos;s secret.
            </p>
          </div>

          <div className="space-y-2">
            <Label htmlFor="webhookScope" className="text-foreground">
              Scope
            </Label>
            {isEdit ? (
              <>
                <Input
                  id="webhookScope"
                  value={
                    webhook?.projectId
                      ? `Project: ${scopedProject?.name ?? webhook.projectId}`
                      : "Entire organization"
                  }
                  className="bg-muted/50 text-muted-foreground"
                  disabled
                />
                <p className="text-xs text-muted-foreground">
                  The scope cannot be changed after creation.
                </p>
              </>
            ) : (
              <>
                <Select
                  value={projectId}
                  onValueChange={setProjectId}
                  disabled={isPending}
                >
                  <SelectTrigger
                    id="webhookScope"
                    className="bg-background border-border text-foreground"
                  >
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value={ORG_SCOPE}>
                      Entire organization
                    </SelectItem>
                    {projects.map((project) => (
                      <SelectItem key={project.id} value={project.id}>
                        {project.name}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
                <p className="text-xs text-muted-foreground">
                  Limit notifications to a single project, or receive events
                  from the whole organization.
                </p>
              </>
            )}
          </div>

          <div className="space-y-2">
            <Label className="text-foreground">Event Types</Label>
            <div className="space-y-1.5 rounded-md border border-border bg-background p-3">
              {WEBHOOK_EVENT_TYPES.map((event) => (
                <label
                  key={event.type}
                  className="flex items-start gap-2 text-sm"
                >
                  <input
                    type="checkbox"
                    checked={selectedEvents.has(event.type)}
                    onChange={() => toggleEvent(event.type)}
                    disabled={isPending}
                    className="mt-0.5 h-4 w-4 rounded border-input bg-background accent-blue-600"
                  />
                  <span>
                    <span className="text-foreground">{event.label}</span>{" "}
                    <span className="font-mono text-xs text-muted-foreground">
                      ({event.type})
                    </span>
                    <span className="block text-xs text-muted-foreground">
                      {event.description}
                    </span>
                  </span>
                </label>
              ))}
            </div>
            <p className="text-xs text-muted-foreground">
              Leave all unchecked to subscribe to every event type.
            </p>
          </div>

          {isEdit && (
            <div className="space-y-2">
              <Label className="text-foreground">Delivery</Label>
              <label className="flex items-center gap-2 text-sm text-foreground">
                <input
                  type="checkbox"
                  checked={isActive}
                  onChange={(e) => setIsActive(e.target.checked)}
                  disabled={isPending}
                  className="h-4 w-4 rounded border-input bg-background accent-blue-600"
                />
                Active
              </label>
              {webhook?.disabledReason && !isActive && (
                <p className="text-xs text-amber-700 dark:text-amber-400">
                  Automatically disabled: {webhook.disabledReason}. Re-enable
                  once the endpoint is fixed.
                </p>
              )}
            </div>
          )}
        </div>

        <DialogFooter>
          <Button
            type="button"
            variant="outline"
            className="border-input"
            onClick={() => onOpenChange(false)}
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
                {isEdit ? "Saving..." : "Creating..."}
              </>
            ) : isEdit ? (
              "Save Changes"
            ) : (
              "Create Webhook"
            )}
          </Button>
        </DialogFooter>
      </form>
    </>
  );
}
