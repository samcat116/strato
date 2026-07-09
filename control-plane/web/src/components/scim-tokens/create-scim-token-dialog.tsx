"use client";

import { useState } from "react";
import { Loader2, Copy, Check } from "lucide-react";
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
  useCreateSCIMToken,
  scimTokenErrorMessage,
} from "@/lib/hooks/use-scim-tokens";
import { toast } from "sonner";
import type { CreateSCIMTokenResponse } from "@/types/api";

interface CreateSCIMTokenDialogProps {
  orgId: string;
  open: boolean;
  onOpenChange: (open: boolean) => void;
}

export function CreateSCIMTokenDialog({
  orgId,
  open,
  onOpenChange,
}: CreateSCIMTokenDialogProps) {
  const createToken = useCreateSCIMToken(orgId);
  const [name, setName] = useState("");
  const [expiresInDays, setExpiresInDays] = useState("");
  const [createdToken, setCreatedToken] =
    useState<CreateSCIMTokenResponse | null>(null);
  const [copied, setCopied] = useState(false);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!name.trim()) {
      toast.error("Please enter a name for the token");
      return;
    }

    const days = expiresInDays.trim() ? parseInt(expiresInDays, 10) : undefined;
    if (days !== undefined && (isNaN(days) || days < 1)) {
      toast.error("Expiration must be a positive number of days");
      return;
    }

    try {
      const token = await createToken.mutateAsync({
        name: name.trim(),
        expiresInDays: days,
      });
      setCreatedToken(token);
    } catch (error) {
      toast.error(scimTokenErrorMessage(error, "Failed to create SCIM token"));
    }
  };

  const handleCopy = async () => {
    if (!createdToken) return;
    await navigator.clipboard.writeText(createdToken.token);
    setCopied(true);
    toast.success("SCIM token copied to clipboard");
    setTimeout(() => setCopied(false), 2000);
  };

  const handleClose = () => {
    onOpenChange(false);
    // Reset state after close animation
    setTimeout(() => {
      setName("");
      setExpiresInDays("");
      setCreatedToken(null);
      setCopied(false);
    }, 200);
  };

  return (
    <Dialog open={open} onOpenChange={handleClose}>
      <DialogContent className="bg-card border-border text-foreground max-h-[85vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>
            {createdToken ? "SCIM Token Created" : "Create SCIM Token"}
          </DialogTitle>
          <DialogDescription className="text-muted-foreground">
            {createdToken
              ? "Copy your token now — it won't be shown again"
              : "Create a bearer token for your identity provider's SCIM provisioning integration"}
          </DialogDescription>
        </DialogHeader>

        {createdToken ? (
          <div className="space-y-4 py-4">
            <div className="p-4 bg-background rounded-lg border border-border">
              <Label className="text-muted-foreground text-sm">
                Your new SCIM token
              </Label>
              <div className="flex items-center gap-2 mt-2">
                <code className="flex-1 min-w-0 p-2 bg-gray-950 rounded text-sm text-green-400 font-mono overflow-x-auto whitespace-nowrap">
                  {createdToken.token}
                </code>
                <Button
                  size="sm"
                  variant="outline"
                  className="border-input shrink-0"
                  onClick={handleCopy}
                >
                  {copied ? (
                    <Check className="h-4 w-4 text-green-600" />
                  ) : (
                    <Copy className="h-4 w-4" />
                  )}
                </Button>
              </div>
            </div>

            <div className="p-4 bg-blue-500/10 rounded-lg border border-blue-500/30">
              <p className="text-sm text-blue-800">
                <strong>Important:</strong> Configure this token in your
                identity provider now. For security reasons, it cannot be
                retrieved again after you close this dialog.
              </p>
              {createdToken.expiresAt && (
                <p className="text-sm text-muted-foreground mt-2">
                  Expires: {new Date(createdToken.expiresAt).toLocaleString()}
                </p>
              )}
            </div>

            <DialogFooter>
              <Button
                className="bg-primary hover:bg-primary/90"
                onClick={handleClose}
              >
                Done
              </Button>
            </DialogFooter>
          </div>
        ) : (
          <form onSubmit={handleSubmit}>
            <div className="space-y-4 py-4">
              <div className="space-y-2">
                <Label htmlFor="scimTokenName" className="text-foreground">
                  Name
                </Label>
                <Input
                  id="scimTokenName"
                  placeholder="e.g. Okta provisioning"
                  value={name}
                  onChange={(e) => setName(e.target.value)}
                  className="bg-background border-border text-foreground"
                  disabled={createToken.isPending}
                />
              </div>

              <div className="space-y-2">
                <Label htmlFor="scimTokenExpires" className="text-foreground">
                  Expiration (days)
                </Label>
                <Input
                  id="scimTokenExpires"
                  type="number"
                  min="1"
                  placeholder="Never expires"
                  value={expiresInDays}
                  onChange={(e) => setExpiresInDays(e.target.value)}
                  className="bg-background border-border text-foreground"
                  disabled={createToken.isPending}
                />
                <p className="text-xs text-muted-foreground">
                  Leave blank for a token that never expires.
                </p>
              </div>
            </div>

            <DialogFooter>
              <Button
                type="button"
                variant="outline"
                className="border-input"
                onClick={handleClose}
                disabled={createToken.isPending}
              >
                Cancel
              </Button>
              <Button
                type="submit"
                className="bg-primary hover:bg-primary/90"
                disabled={createToken.isPending}
              >
                {createToken.isPending ? (
                  <>
                    <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                    Creating...
                  </>
                ) : (
                  "Create Token"
                )}
              </Button>
            </DialogFooter>
          </form>
        )}
      </DialogContent>
    </Dialog>
  );
}
