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
import { useCreateAPIKey } from "@/lib/hooks";
import { toast } from "sonner";
import type { CreateAPIKeyResponse } from "@/types/api";

interface CreateAPIKeyDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
}

const AVAILABLE_SCOPES: { value: string; label: string; description: string }[] =
  [
    { value: "read", label: "Read", description: "View resources" },
    { value: "write", label: "Write", description: "Create and modify resources" },
    { value: "admin", label: "Admin", description: "Full administrative access" },
  ];

export function CreateAPIKeyDialog({
  open,
  onOpenChange,
}: CreateAPIKeyDialogProps) {
  const createKey = useCreateAPIKey();
  const [name, setName] = useState("");
  const [scopes, setScopes] = useState<string[]>(["read", "write"]);
  const [expiresInDays, setExpiresInDays] = useState("");
  const [createdKey, setCreatedKey] = useState<CreateAPIKeyResponse | null>(
    null
  );
  const [copied, setCopied] = useState(false);

  const toggleScope = (scope: string) => {
    setScopes((prev) =>
      prev.includes(scope)
        ? prev.filter((s) => s !== scope)
        : [...prev, scope]
    );
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!name.trim()) {
      toast.error("Please enter a name for the API key");
      return;
    }

    if (scopes.length === 0) {
      toast.error("Please select at least one scope");
      return;
    }

    const days = expiresInDays.trim() ? parseInt(expiresInDays, 10) : undefined;
    if (days !== undefined && (isNaN(days) || days < 1 || days > 365)) {
      toast.error("Expiration must be between 1 and 365 days");
      return;
    }

    try {
      const key = await createKey.mutateAsync({
        name: name.trim(),
        scopes,
        expiresInDays: days,
      });
      setCreatedKey(key);
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : "Failed to create API key"
      );
    }
  };

  const handleCopy = async () => {
    if (!createdKey) return;
    await navigator.clipboard.writeText(createdKey.key);
    setCopied(true);
    toast.success("API key copied to clipboard");
    setTimeout(() => setCopied(false), 2000);
  };

  const handleClose = () => {
    onOpenChange(false);
    // Reset state after close animation
    setTimeout(() => {
      setName("");
      setScopes(["read", "write"]);
      setExpiresInDays("");
      setCreatedKey(null);
      setCopied(false);
    }, 200);
  };

  return (
    <Dialog open={open} onOpenChange={handleClose}>
      <DialogContent className="bg-card border-border text-foreground sm:max-w-2xl max-h-[85vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>
            {createdKey ? "API Key Created" : "Create API Key"}
          </DialogTitle>
          <DialogDescription className="text-muted-foreground">
            {createdKey
              ? "Copy your API key now — it won't be shown again"
              : "Create a new API key to access the Strato API"}
          </DialogDescription>
        </DialogHeader>

        {createdKey ? (
          <div className="space-y-4 py-4 min-w-0">
            <div className="p-4 bg-background rounded-lg border border-border">
              <Label className="text-muted-foreground text-sm">Your new API key</Label>
              <div className="flex items-start gap-2 mt-2">
                <code className="flex-1 min-w-0 p-2 bg-gray-950 rounded text-sm text-green-400 font-mono whitespace-pre-wrap break-all">
                  {createdKey.key}
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
                <strong>Important:</strong> Store this key somewhere safe. For
                security reasons, it cannot be retrieved again after you close
                this dialog.
              </p>
              {createdKey.expiresAt && (
                <p className="text-sm text-muted-foreground mt-2">
                  Expires: {new Date(createdKey.expiresAt).toLocaleString()}
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
                <Label htmlFor="keyName" className="text-foreground">
                  Name
                </Label>
                <Input
                  id="keyName"
                  placeholder="e.g. CI pipeline"
                  value={name}
                  onChange={(e) => setName(e.target.value)}
                  className="bg-background border-border text-foreground"
                  disabled={createKey.isPending}
                />
              </div>

              <div className="space-y-2">
                <Label className="text-foreground">Scopes</Label>
                <div className="space-y-2">
                  {AVAILABLE_SCOPES.map((scope) => (
                    <label
                      key={scope.value}
                      className="flex items-start gap-3 p-2 rounded-md hover:bg-accent/60 cursor-pointer"
                    >
                      <input
                        type="checkbox"
                        checked={scopes.includes(scope.value)}
                        onChange={() => toggleScope(scope.value)}
                        disabled={createKey.isPending}
                        className="mt-0.5 h-4 w-4 rounded border-input bg-background accent-blue-600"
                      />
                      <span>
                        <span className="block text-sm text-foreground">
                          {scope.label}
                        </span>
                        <span className="block text-xs text-muted-foreground">
                          {scope.description}
                        </span>
                      </span>
                    </label>
                  ))}
                </div>
              </div>

              <div className="space-y-2">
                <Label htmlFor="expiresInDays" className="text-foreground">
                  Expiration (days)
                </Label>
                <Input
                  id="expiresInDays"
                  type="number"
                  min="1"
                  max="365"
                  placeholder="Never expires"
                  value={expiresInDays}
                  onChange={(e) => setExpiresInDays(e.target.value)}
                  className="bg-background border-border text-foreground"
                  disabled={createKey.isPending}
                />
                <p className="text-xs text-muted-foreground">
                  Leave blank for a key that never expires (max 365 days).
                </p>
              </div>
            </div>

            <DialogFooter>
              <Button
                type="button"
                variant="outline"
                className="border-input"
                onClick={handleClose}
                disabled={createKey.isPending}
              >
                Cancel
              </Button>
              <Button
                type="submit"
                className="bg-primary hover:bg-primary/90"
                disabled={createKey.isPending}
              >
                {createKey.isPending ? (
                  <>
                    <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                    Creating...
                  </>
                ) : (
                  "Create Key"
                )}
              </Button>
            </DialogFooter>
          </form>
        )}
      </DialogContent>
    </Dialog>
  );
}
