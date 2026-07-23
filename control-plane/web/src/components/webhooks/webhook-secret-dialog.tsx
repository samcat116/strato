"use client";

import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Label } from "@/components/ui/label";
import { CopyButton } from "@/components/ui/copy-button";
import type { WebhookWithSecret } from "@/types/api";

interface WebhookSecretDialogProps {
  /** The create/rotate result to reveal; null keeps the dialog closed. */
  result: WebhookWithSecret | null;
  /** Whether the secret comes from a rotation (vs. initial creation). */
  rotated?: boolean;
  onClose: () => void;
}

/**
 * One-time reveal of a webhook signing secret after create or rotate. The
 * secret is stored hashed server-side and can never be shown again.
 */
export function WebhookSecretDialog({
  result,
  rotated = false,
  onClose,
}: WebhookSecretDialogProps) {
  return (
    <Dialog
      open={!!result}
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
    >
      <DialogContent className="bg-card border-border text-foreground">
        <DialogHeader>
          <DialogTitle>
            {rotated ? "Signing Secret Rotated" : "Webhook Created"}
          </DialogTitle>
          <DialogDescription className="text-muted-foreground">
            Copy the signing secret now — it won&apos;t be shown again
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-4 py-4">
          <div className="p-4 bg-background rounded-lg border border-border">
            <Label className="text-muted-foreground text-sm">
              Signing secret for {result?.subscription.name}
            </Label>
            <div className="flex items-center gap-2 mt-2">
              <code className="flex-1 min-w-0 p-2 bg-gray-950 rounded text-sm text-green-400 font-mono overflow-x-auto whitespace-nowrap">
                {result?.signingSecret}
              </code>
              {result && (
                <CopyButton
                  value={result.signingSecret}
                  label="Copy signing secret"
                  toastMessage="Signing secret copied to clipboard"
                  variant="outline"
                  size="sm"
                  className="border-input"
                />
              )}
            </div>
          </div>

          <div className="p-4 bg-blue-500/10 rounded-lg border border-blue-500/30">
            <p className="text-sm text-blue-800">
              <strong>Important:</strong> Store this secret in your receiving
              service now and use it to verify the signature on incoming
              deliveries. It cannot be retrieved again after you close this
              dialog{rotated ? ", and the previous secret no longer works" : ""}
              .
            </p>
          </div>

          <DialogFooter>
            <Button className="bg-primary hover:bg-primary/90" onClick={onClose}>
              Done
            </Button>
          </DialogFooter>
        </div>
      </DialogContent>
    </Dialog>
  );
}
