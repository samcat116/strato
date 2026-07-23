"use client";

import { useState } from "react";
import { KeyRound, Loader2, Plus, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { WebhooksTable } from "./webhooks-table";
import { WebhookFormDialog } from "./webhook-form-dialog";
import { WebhookSecretDialog } from "./webhook-secret-dialog";
import { WebhookDeliveriesDialog } from "./webhook-deliveries-dialog";
import {
  useWebhooks,
  useDeleteWebhook,
  useRotateWebhookSecret,
  useSendTestWebhook,
  webhookErrorMessage,
} from "@/lib/hooks/use-webhooks";
import { useProjectsForOrganization } from "@/lib/hooks";
import { toast } from "sonner";
import type { WebhookSubscription, WebhookWithSecret } from "@/types/api";

interface WebhooksSectionProps {
  orgId: string;
  canManage: boolean;
}

export function WebhooksSection({ orgId, canManage }: WebhooksSectionProps) {
  const [formOpen, setFormOpen] = useState(false);
  const [editTarget, setEditTarget] = useState<WebhookSubscription | null>(null);
  const [deleteTarget, setDeleteTarget] = useState<WebhookSubscription | null>(
    null
  );
  const [rotateTarget, setRotateTarget] = useState<WebhookSubscription | null>(
    null
  );
  const [deliveriesTarget, setDeliveriesTarget] =
    useState<WebhookSubscription | null>(null);
  const [secretResult, setSecretResult] = useState<{
    result: WebhookWithSecret;
    rotated: boolean;
  } | null>(null);
  const [testingId, setTestingId] = useState<string | null>(null);

  const { data: webhooks = [], isLoading } = useWebhooks(orgId);
  const { data: projects = [] } = useProjectsForOrganization(orgId);
  const deleteWebhook = useDeleteWebhook(orgId);
  const rotateSecret = useRotateWebhookSecret(orgId);
  const sendTest = useSendTestWebhook(orgId);

  const openCreate = () => {
    setEditTarget(null);
    setFormOpen(true);
  };

  const openEdit = (webhook: WebhookSubscription) => {
    setEditTarget(webhook);
    setFormOpen(true);
  };

  const handleSendTest = async (webhook: WebhookSubscription) => {
    setTestingId(webhook.id);
    try {
      await sendTest.mutateAsync(webhook.id);
      toast.success(
        `Test event enqueued for "${webhook.name}" — check the deliveries view for the result`
      );
    } catch (error) {
      toast.error(webhookErrorMessage(error, "Failed to send test event"));
    } finally {
      setTestingId(null);
    }
  };

  const handleRotate = async () => {
    if (!rotateTarget) return;
    try {
      const result = await rotateSecret.mutateAsync(rotateTarget.id);
      setRotateTarget(null);
      setSecretResult({ result, rotated: true });
    } catch (error) {
      toast.error(webhookErrorMessage(error, "Failed to rotate secret"));
    }
  };

  const handleDelete = async () => {
    if (!deleteTarget) return;
    try {
      await deleteWebhook.mutateAsync(deleteTarget.id);
      toast.success(`Webhook "${deleteTarget.name}" deleted`);
      setDeleteTarget(null);
    } catch (error) {
      toast.error(webhookErrorMessage(error, "Failed to delete webhook"));
    }
  };

  return (
    <Card className="bg-card border-border">
      <CardHeader className="flex flex-row items-center justify-between space-y-0">
        <CardTitle className="text-lg font-semibold text-foreground">
          Webhooks
        </CardTitle>
        {canManage && (
          <Button
            size="sm"
            className="bg-primary hover:bg-primary/90"
            onClick={openCreate}
          >
            <Plus className="h-4 w-4 mr-2" />
            Create Webhook
          </Button>
        )}
      </CardHeader>
      <CardContent>
        <p className="text-sm text-muted-foreground mb-4">
          Webhooks deliver signed HTTP POST notifications to your endpoints
          when events happen — operations completing or failing, VM state
          changes, agents connecting or disconnecting, and quota thresholds.
          Endpoints that fail continuously are disabled automatically.
          {!canManage &&
            " You need admin rights on this organization to create, edit, or delete them."}
        </p>

        <WebhooksTable
          webhooks={webhooks}
          isLoading={isLoading}
          canManage={canManage}
          projects={projects}
          testingId={testingId}
          onSendTest={handleSendTest}
          onViewDeliveries={setDeliveriesTarget}
          onEdit={openEdit}
          onRotateSecret={setRotateTarget}
          onDelete={setDeleteTarget}
        />
      </CardContent>

      {canManage && (
        <WebhookFormDialog
          orgId={orgId}
          open={formOpen}
          onOpenChange={setFormOpen}
          webhook={editTarget}
          projects={projects}
          onCreated={(result) => setSecretResult({ result, rotated: false })}
        />
      )}

      {/* One-time signing-secret reveal after create or rotate */}
      <WebhookSecretDialog
        result={secretResult?.result ?? null}
        rotated={secretResult?.rotated ?? false}
        onClose={() => setSecretResult(null)}
      />

      <WebhookDeliveriesDialog
        orgId={orgId}
        webhook={deliveriesTarget}
        canManage={canManage}
        onClose={() => setDeliveriesTarget(null)}
      />

      {/* Rotate-secret confirmation dialog */}
      <Dialog
        open={!!rotateTarget}
        onOpenChange={(open) => {
          if (!open) setRotateTarget(null);
        }}
      >
        <DialogContent className="bg-card border-border text-foreground">
          <DialogHeader>
            <DialogTitle>Rotate secret for {rotateTarget?.name}?</DialogTitle>
            <DialogDescription className="text-muted-foreground">
              A new signing secret is generated and shown once. The current
              secret stops working immediately, so deliveries will fail
              signature verification until your endpoint uses the new one.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button
              variant="outline"
              className="border-input"
              onClick={() => setRotateTarget(null)}
              disabled={rotateSecret.isPending}
            >
              Cancel
            </Button>
            <Button
              className="bg-primary hover:bg-primary/90"
              onClick={handleRotate}
              disabled={rotateSecret.isPending}
            >
              {rotateSecret.isPending ? (
                <Loader2 className="h-4 w-4 animate-spin" />
              ) : (
                <KeyRound className="h-4 w-4" />
              )}
              Rotate Secret
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* Delete confirmation dialog */}
      <Dialog
        open={!!deleteTarget}
        onOpenChange={(open) => {
          if (!open) setDeleteTarget(null);
        }}
      >
        <DialogContent className="bg-card border-border text-foreground">
          <DialogHeader>
            <DialogTitle>Delete {deleteTarget?.name}?</DialogTitle>
            <DialogDescription className="text-muted-foreground">
              The webhook and its delivery history are removed, and no further
              events will be sent to this endpoint. This cannot be undone.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button
              variant="outline"
              className="border-input"
              onClick={() => setDeleteTarget(null)}
              disabled={deleteWebhook.isPending}
            >
              Cancel
            </Button>
            <Button
              variant="destructive"
              onClick={handleDelete}
              disabled={deleteWebhook.isPending}
            >
              {deleteWebhook.isPending ? (
                <Loader2 className="h-4 w-4 animate-spin" />
              ) : (
                <Trash2 className="h-4 w-4" />
              )}
              Delete
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </Card>
  );
}
