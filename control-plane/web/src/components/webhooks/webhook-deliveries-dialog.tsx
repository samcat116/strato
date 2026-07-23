"use client";

import { useState } from "react";
import { ChevronDown, ChevronRight, Loader2, RotateCw, Send } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
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
import {
  useRedeliverWebhookDelivery,
  useSendTestWebhook,
  useWebhookDeliveries,
  webhookErrorMessage,
} from "@/lib/hooks/use-webhooks";
import { toast } from "sonner";
import type { WebhookDelivery, WebhookSubscription } from "@/types/api";

interface WebhookDeliveriesDialogProps {
  orgId: string;
  /** The subscription whose deliveries to show; null keeps the dialog closed. */
  webhook: WebhookSubscription | null;
  canManage: boolean;
  onClose: () => void;
}

function statusBadgeClass(status: WebhookDelivery["status"]): string {
  switch (status) {
    case "succeeded":
      return "bg-emerald-900/30 text-emerald-700 border-transparent";
    case "dead":
      return "bg-red-900/40 text-red-700 border-transparent";
    default:
      return "bg-amber-900/30 text-amber-700 border-transparent";
  }
}

function formatTimestamp(value?: string | null): string {
  if (!value) return "—";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return date.toLocaleString(undefined, {
    year: "numeric",
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
}

function prettyPayload(payload: string): string {
  try {
    return JSON.stringify(JSON.parse(payload), null, 2);
  } catch {
    return payload;
  }
}

export function WebhookDeliveriesDialog({
  orgId,
  webhook,
  canManage,
  onClose,
}: WebhookDeliveriesDialogProps) {
  const [expandedId, setExpandedId] = useState<string | null>(null);
  const [redeliveringId, setRedeliveringId] = useState<string | null>(null);

  const { data: deliveries = [], isLoading } = useWebhookDeliveries(
    orgId,
    webhook?.id,
    !!webhook
  );
  const redeliver = useRedeliverWebhookDelivery(orgId);
  const sendTest = useSendTestWebhook(orgId);

  const handleRedeliver = async (delivery: WebhookDelivery) => {
    if (!webhook) return;
    setRedeliveringId(delivery.id);
    try {
      await redeliver.mutateAsync({
        webhookId: webhook.id,
        deliveryId: delivery.id,
      });
      toast.success("Redelivery enqueued");
    } catch (error) {
      toast.error(webhookErrorMessage(error, "Failed to redeliver"));
    } finally {
      setRedeliveringId(null);
    }
  };

  const handleSendTest = async () => {
    if (!webhook) return;
    try {
      await sendTest.mutateAsync(webhook.id);
      toast.success("Test event enqueued");
    } catch (error) {
      toast.error(webhookErrorMessage(error, "Failed to send test event"));
    }
  };

  return (
    <Dialog
      open={!!webhook}
      onOpenChange={(open) => {
        if (!open) {
          setExpandedId(null);
          onClose();
        }
      }}
    >
      <DialogContent className="bg-card border-border text-foreground sm:max-w-4xl max-h-[85vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>Deliveries — {webhook?.name}</DialogTitle>
          <DialogDescription className="text-muted-foreground">
            Recent delivery attempts, newest first. Pending deliveries retry
            automatically; this list refreshes every few seconds.
          </DialogDescription>
        </DialogHeader>

        {canManage && (
          <div className="flex justify-end">
            <Button
              size="sm"
              variant="outline"
              className="border-input"
              onClick={handleSendTest}
              disabled={!webhook?.isActive || sendTest.isPending}
              title={
                webhook?.isActive
                  ? "Enqueue a webhook.test delivery"
                  : "Enable the webhook to send a test event"
              }
            >
              {sendTest.isPending ? (
                <Loader2 className="h-4 w-4 mr-2 animate-spin" />
              ) : (
                <Send className="h-4 w-4 mr-2" />
              )}
              Send test event
            </Button>
          </div>
        )}

        {isLoading ? (
          <div className="space-y-2">
            {[...Array(3)].map((_, i) => (
              <Skeleton key={i} className="h-10 w-full bg-muted" />
            ))}
          </div>
        ) : deliveries.length === 0 ? (
          <div className="text-center py-8 text-muted-foreground">
            No deliveries yet.
            {canManage && webhook?.isActive && " Send a test event to try it."}
          </div>
        ) : (
          <Table>
            <TableHeader className="bg-background">
              <TableRow className="border-border hover:bg-transparent">
                <TableHead className="w-8" />
                <TableHead className="text-muted-foreground font-medium">
                  Time
                </TableHead>
                <TableHead className="text-muted-foreground font-medium">
                  Event
                </TableHead>
                <TableHead className="text-muted-foreground font-medium">
                  Status
                </TableHead>
                <TableHead className="text-muted-foreground font-medium">
                  Attempts
                </TableHead>
                <TableHead className="text-muted-foreground font-medium">
                  HTTP
                </TableHead>
                <TableHead className="text-muted-foreground font-medium">
                  Error
                </TableHead>
                {canManage && (
                  <TableHead className="text-muted-foreground font-medium text-right">
                    Actions
                  </TableHead>
                )}
              </TableRow>
            </TableHeader>
            <TableBody className="divide-y divide-border">
              {deliveries.map((delivery) => {
                const expanded = expandedId === delivery.id;
                const columns = canManage ? 8 : 7;
                return (
                  <DeliveryRows
                    key={delivery.id}
                    delivery={delivery}
                    expanded={expanded}
                    columns={columns}
                    canManage={canManage}
                    webhookActive={!!webhook?.isActive}
                    redelivering={redeliveringId === delivery.id}
                    onToggle={() =>
                      setExpandedId(expanded ? null : delivery.id)
                    }
                    onRedeliver={() => handleRedeliver(delivery)}
                  />
                );
              })}
            </TableBody>
          </Table>
        )}
      </DialogContent>
    </Dialog>
  );
}

function DeliveryRows({
  delivery,
  expanded,
  columns,
  canManage,
  webhookActive,
  redelivering,
  onToggle,
  onRedeliver,
}: {
  delivery: WebhookDelivery;
  expanded: boolean;
  columns: number;
  canManage: boolean;
  webhookActive: boolean;
  redelivering: boolean;
  onToggle: () => void;
  onRedeliver: () => void;
}) {
  const canRedeliver =
    canManage && webhookActive && delivery.status !== "pending";
  return (
    <>
      <TableRow className="border-border hover:bg-accent/60">
        <TableCell className="pr-0">
          <Button
            size="icon-sm"
            variant="ghost"
            className="text-muted-foreground hover:text-foreground"
            onClick={onToggle}
            aria-label={expanded ? "Hide payload" : "Show payload"}
            title={expanded ? "Hide payload" : "Show payload"}
          >
            {expanded ? (
              <ChevronDown className="h-4 w-4" />
            ) : (
              <ChevronRight className="h-4 w-4" />
            )}
          </Button>
        </TableCell>
        <TableCell className="text-muted-foreground text-sm whitespace-nowrap">
          {formatTimestamp(delivery.createdAt)}
        </TableCell>
        <TableCell className="font-mono text-sm text-foreground">
          {delivery.eventType}
        </TableCell>
        <TableCell>
          <Badge
            className={statusBadgeClass(delivery.status)}
            title={
              delivery.status === "pending" && delivery.nextAttemptAt
                ? `Next attempt ${formatTimestamp(delivery.nextAttemptAt)}`
                : delivery.status === "succeeded" && delivery.deliveredAt
                  ? `Delivered ${formatTimestamp(delivery.deliveredAt)}`
                  : undefined
            }
          >
            {delivery.status}
          </Badge>
        </TableCell>
        <TableCell className="text-muted-foreground text-sm">
          {delivery.attempts}
        </TableCell>
        <TableCell className="text-muted-foreground text-sm font-mono">
          {delivery.responseStatus ?? "—"}
        </TableCell>
        <TableCell
          className="text-muted-foreground text-sm max-w-48 truncate"
          title={delivery.lastError ?? undefined}
        >
          {delivery.lastError ?? "—"}
        </TableCell>
        {canManage && (
          <TableCell className="text-right">
            <Button
              size="icon-sm"
              variant="ghost"
              className="text-muted-foreground hover:text-foreground"
              onClick={onRedeliver}
              disabled={!canRedeliver || redelivering}
              aria-label="Redeliver this event"
              title={
                delivery.status === "pending"
                  ? "Still pending — retries happen automatically"
                  : !webhookActive
                    ? "Enable the webhook to redeliver"
                    : "Redeliver"
              }
            >
              {redelivering ? (
                <Loader2 className="h-4 w-4 animate-spin" />
              ) : (
                <RotateCw className="h-4 w-4" />
              )}
            </Button>
          </TableCell>
        )}
      </TableRow>
      {expanded && (
        <TableRow className="border-border hover:bg-transparent">
          <TableCell colSpan={columns} className="bg-background">
            <div className="space-y-1 py-1">
              <p className="text-xs text-muted-foreground">
                Payload (event <span className="font-mono">{delivery.eventId}</span>)
              </p>
              <pre className="max-h-64 overflow-auto rounded-md border border-border bg-gray-950 p-3 text-xs font-mono text-green-400 whitespace-pre">
                {prettyPayload(delivery.payload)}
              </pre>
            </div>
          </TableCell>
        </TableRow>
      )}
    </>
  );
}
