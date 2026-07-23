"use client";

import { AlertTriangle, History, KeyRound, Loader2, Pencil, Send, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { Skeleton } from "@/components/ui/skeleton";
import { webhookEventLabel } from "./event-catalog";
import type { Project } from "@/lib/api/projects";
import type { WebhookSubscription } from "@/types/api";

interface WebhooksTableProps {
  webhooks: WebhookSubscription[];
  isLoading: boolean;
  canManage: boolean;
  /** Org projects, used to resolve project-scoped subscriptions to a name. */
  projects: Project[];
  /** Webhook id with a test send in flight, if any. */
  testingId?: string | null;
  onSendTest: (webhook: WebhookSubscription) => void;
  onViewDeliveries: (webhook: WebhookSubscription) => void;
  onEdit: (webhook: WebhookSubscription) => void;
  onRotateSecret: (webhook: WebhookSubscription) => void;
  onDelete: (webhook: WebhookSubscription) => void;
}

const MAX_EVENT_BADGES = 3;

function scopeLabel(
  webhook: WebhookSubscription,
  projects: Project[]
): { text: string; title?: string } {
  if (!webhook.projectId) return { text: "Organization" };
  const project = projects.find((p) => p.id === webhook.projectId);
  if (project) return { text: project.name, title: webhook.projectId };
  return { text: `${webhook.projectId.slice(0, 8)}…`, title: webhook.projectId };
}

export function WebhooksTable({
  webhooks,
  isLoading,
  canManage,
  projects,
  testingId,
  onSendTest,
  onViewDeliveries,
  onEdit,
  onRotateSecret,
  onDelete,
}: WebhooksTableProps) {
  if (isLoading) {
    return (
      <div className="space-y-2">
        {[...Array(2)].map((_, i) => (
          <Skeleton key={i} className="h-12 w-full bg-muted" />
        ))}
      </div>
    );
  }

  if (webhooks.length === 0) {
    return (
      <div className="text-center py-8 text-muted-foreground">
        No webhooks configured.
        {canManage && " Create one to receive event notifications over HTTP."}
      </div>
    );
  }

  return (
    <Table>
      <TableHeader className="bg-background">
        <TableRow className="border-border hover:bg-transparent">
          <TableHead className="text-muted-foreground font-medium">
            Name
          </TableHead>
          <TableHead className="text-muted-foreground font-medium">
            URL
          </TableHead>
          <TableHead className="text-muted-foreground font-medium">
            Events
          </TableHead>
          <TableHead className="text-muted-foreground font-medium">
            Scope
          </TableHead>
          <TableHead className="text-muted-foreground font-medium">
            Status
          </TableHead>
          <TableHead className="text-muted-foreground font-medium text-right">
            Actions
          </TableHead>
        </TableRow>
      </TableHeader>
      <TableBody className="divide-y divide-border">
        {webhooks.map((webhook) => {
          const scope = scopeLabel(webhook, projects);
          const shownEvents = webhook.eventTypes.slice(0, MAX_EVENT_BADGES);
          const extraEvents = webhook.eventTypes.length - shownEvents.length;
          return (
            <TableRow
              key={webhook.id}
              className="border-border hover:bg-accent/60"
            >
              <TableCell>
                <span className="font-medium text-foreground">
                  {webhook.name}
                </span>
              </TableCell>
              <TableCell
                className="text-foreground/80 font-mono text-sm max-w-48 truncate"
                title={webhook.url}
              >
                {webhook.url}
              </TableCell>
              <TableCell>
                <div className="flex flex-wrap items-center gap-1">
                  {webhook.eventTypes.length === 0 ? (
                    <Badge className="bg-muted text-foreground/80 border-transparent">
                      All events
                    </Badge>
                  ) : (
                    <>
                      {shownEvents.map((type) => (
                        <Badge
                          key={type}
                          className="bg-muted text-foreground/80 border-transparent"
                          title={type}
                        >
                          {webhookEventLabel(type)}
                        </Badge>
                      ))}
                      {extraEvents > 0 && (
                        <Badge
                          className="bg-muted text-foreground/80 border-transparent"
                          title={webhook.eventTypes
                            .slice(MAX_EVENT_BADGES)
                            .map(webhookEventLabel)
                            .join(", ")}
                        >
                          +{extraEvents} more
                        </Badge>
                      )}
                    </>
                  )}
                </div>
              </TableCell>
              <TableCell
                className="text-foreground/80 text-sm max-w-32 truncate"
                title={scope.title}
              >
                {scope.text}
              </TableCell>
              <TableCell>
                <div className="flex flex-col gap-1">
                  <div className="flex flex-wrap items-center gap-1">
                    {webhook.isActive ? (
                      <Badge className="bg-green-500/10 text-green-700 border-transparent">
                        Active
                      </Badge>
                    ) : (
                      <Badge className="bg-muted text-foreground/80 border-transparent">
                        Disabled
                      </Badge>
                    )}
                    {webhook.isActive && webhook.failingSince && (
                      <Badge
                        className="bg-amber-900/30 text-amber-700 border-transparent gap-1"
                        title={`Deliveries have been failing since ${new Date(
                          webhook.failingSince
                        ).toLocaleString()}`}
                      >
                        <AlertTriangle className="h-3 w-3" />
                        Failing
                      </Badge>
                    )}
                  </div>
                  {webhook.disabledReason && (
                    <span
                      className="flex items-start gap-1 text-xs text-amber-700 dark:text-amber-400 max-w-56"
                      title={webhook.disabledReason}
                    >
                      <AlertTriangle className="h-3.5 w-3.5 mt-0.5 shrink-0" />
                      <span className="line-clamp-2">
                        {webhook.disabledReason}
                      </span>
                    </span>
                  )}
                </div>
              </TableCell>
              <TableCell className="text-right">
                <div className="flex items-center justify-end gap-1">
                  {canManage && (
                    <Button
                      size="icon-sm"
                      variant="ghost"
                      className="text-muted-foreground hover:text-foreground"
                      onClick={() => onSendTest(webhook)}
                      disabled={!webhook.isActive || testingId === webhook.id}
                      aria-label={`Send a test event to ${webhook.name}`}
                      title={
                        webhook.isActive
                          ? "Send test event"
                          : "Enable the webhook to send a test event"
                      }
                    >
                      {testingId === webhook.id ? (
                        <Loader2 className="h-4 w-4 animate-spin" />
                      ) : (
                        <Send className="h-4 w-4" />
                      )}
                    </Button>
                  )}
                  {/* Delivery history is admin-only server-side: payloads
                      carry operational detail from any project in the org. */}
                  {canManage && (
                    <Button
                      size="icon-sm"
                      variant="ghost"
                      className="text-muted-foreground hover:text-foreground"
                      onClick={() => onViewDeliveries(webhook)}
                      aria-label={`View deliveries for ${webhook.name}`}
                      title="View deliveries"
                    >
                      <History className="h-4 w-4" />
                    </Button>
                  )}
                  {canManage && (
                    <>
                      <Button
                        size="icon-sm"
                        variant="ghost"
                        className="text-muted-foreground hover:text-foreground"
                        onClick={() => onEdit(webhook)}
                        aria-label={`Edit ${webhook.name}`}
                        title="Edit"
                      >
                        <Pencil className="h-4 w-4" />
                      </Button>
                      <Button
                        size="icon-sm"
                        variant="ghost"
                        className="text-muted-foreground hover:text-foreground"
                        onClick={() => onRotateSecret(webhook)}
                        aria-label={`Rotate signing secret for ${webhook.name}`}
                        title="Rotate signing secret"
                      >
                        <KeyRound className="h-4 w-4" />
                      </Button>
                      <Button
                        size="icon-sm"
                        variant="ghost"
                        className="text-muted-foreground hover:text-red-600 hover:bg-red-500/10"
                        onClick={() => onDelete(webhook)}
                        aria-label={`Delete ${webhook.name}`}
                        title="Delete"
                      >
                        <Trash2 className="h-4 w-4" />
                      </Button>
                    </>
                  )}
                </div>
              </TableCell>
            </TableRow>
          );
        })}
      </TableBody>
    </Table>
  );
}
