"use client";

import { Suspense, useState } from "react";
import { useSearchParams } from "next/navigation";
import { useQueryClient } from "@tanstack/react-query";
import { Check, Loader2, MonitorSmartphone, X } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  useApproveDevice,
  useDenyDevice,
  usePendingDeviceAuthorization,
} from "@/lib/hooks";
import { toast } from "sonner";

/** Uppercase, strip separators, and re-insert the dash: `bcdfghjk` → `BCDF-GHJK`. */
function normalizeUserCode(raw: string): string {
  const cleaned = raw.toUpperCase().replace(/[^A-Z0-9]/g, "");
  if (cleaned.length <= 4) return cleaned;
  return `${cleaned.slice(0, 4)}-${cleaned.slice(4, 8)}`;
}

function ActivateForm() {
  const searchParams = useSearchParams();
  const initialCode = normalizeUserCode(searchParams.get("code") ?? "");

  const [code, setCode] = useState(initialCode);
  const [submittedCode, setSubmittedCode] = useState<string | null>(
    initialCode.length === 9 ? initialCode : null
  );
  const [outcome, setOutcome] = useState<"approved" | "denied" | null>(null);

  const queryClient = useQueryClient();
  const pending = usePendingDeviceAuthorization(submittedCode);
  const approve = useApproveDevice();
  const deny = useDenyDevice();

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (code.length !== 9) {
      toast.error("Enter the 8-character code shown in your terminal");
      return;
    }
    // Clear any cached 404 so resubmitting the same code retries the lookup.
    queryClient.removeQueries({ queryKey: ["device-authorization", code] });
    setSubmittedCode(code);
  };

  const handleApprove = async () => {
    if (!submittedCode) return;
    try {
      await approve.mutateAsync(submittedCode);
      setOutcome("approved");
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : "Failed to approve the device"
      );
    }
  };

  const handleDeny = async () => {
    if (!submittedCode) return;
    try {
      await deny.mutateAsync(submittedCode);
      setOutcome("denied");
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : "Failed to deny the device"
      );
    }
  };

  if (outcome) {
    return (
      <Card className="bg-card border-border max-w-lg mx-auto">
        <CardHeader className="text-center">
          <div
            className={`mx-auto mb-2 flex h-12 w-12 items-center justify-center rounded-full ${
              outcome === "approved" ? "bg-green-500/10" : "bg-muted"
            }`}
          >
            {outcome === "approved" ? (
              <Check className="h-6 w-6 text-green-600" />
            ) : (
              <X className="h-6 w-6 text-muted-foreground" />
            )}
          </div>
          <CardTitle>
            {outcome === "approved" ? "Device approved" : "Request denied"}
          </CardTitle>
          <CardDescription className="text-muted-foreground">
            {outcome === "approved"
              ? "You can return to your terminal — the CLI will finish signing in on its own."
              : "The sign-in request was denied. You can close this page."}
          </CardDescription>
        </CardHeader>
      </Card>
    );
  }

  if (submittedCode && pending.data) {
    const device = pending.data;
    return (
      <Card className="bg-card border-border max-w-lg mx-auto">
        <CardHeader>
          <div className="mx-auto mb-2 flex h-12 w-12 items-center justify-center rounded-full bg-primary/10">
            <MonitorSmartphone className="h-6 w-6 text-primary" />
          </div>
          <CardTitle className="text-center">Approve this device?</CardTitle>
          <CardDescription className="text-center text-muted-foreground">
            A device is asking to access Strato as you. Only approve if the code
            below matches your terminal.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="text-center font-mono text-2xl tracking-widest text-foreground">
            {device.userCode}
          </div>
          <div className="rounded-lg border border-border bg-background p-4 space-y-2 text-sm">
            <div className="flex justify-between">
              <span className="text-muted-foreground">Device</span>
              <span className="text-foreground font-medium">
                {device.clientName}
              </span>
            </div>
            <div className="flex justify-between items-center">
              <span className="text-muted-foreground">Requested access</span>
              <span className="flex gap-1">
                {device.scopes.map((scope) => (
                  <Badge
                    key={scope}
                    variant="secondary"
                    className="bg-muted text-foreground"
                  >
                    {scope}
                  </Badge>
                ))}
              </span>
            </div>
            {device.requestIP && (
              <div className="flex justify-between">
                <span className="text-muted-foreground">From IP</span>
                <span className="text-foreground font-mono">
                  {device.requestIP}
                </span>
              </div>
            )}
            {device.createdAt && (
              <div className="flex justify-between">
                <span className="text-muted-foreground">Requested</span>
                <span className="text-foreground">
                  {new Date(device.createdAt).toLocaleString()}
                </span>
              </div>
            )}
          </div>
          <div className="flex gap-3">
            <Button
              variant="outline"
              className="flex-1 border-input"
              onClick={handleDeny}
              disabled={approve.isPending || deny.isPending}
            >
              {deny.isPending ? (
                <Loader2 className="h-4 w-4 animate-spin" />
              ) : (
                "Deny"
              )}
            </Button>
            <Button
              className="flex-1 bg-primary hover:bg-primary/90"
              onClick={handleApprove}
              disabled={approve.isPending || deny.isPending}
            >
              {approve.isPending ? (
                <Loader2 className="h-4 w-4 animate-spin" />
              ) : (
                "Approve"
              )}
            </Button>
          </div>
        </CardContent>
      </Card>
    );
  }

  return (
    <Card className="bg-card border-border max-w-lg mx-auto">
      <CardHeader>
        <CardTitle>Connect a device</CardTitle>
        <CardDescription className="text-muted-foreground">
          Enter the code shown by <code className="font-mono">strato login</code>{" "}
          in your terminal.
        </CardDescription>
      </CardHeader>
      <CardContent>
        <form onSubmit={handleSubmit} className="space-y-4">
          <div className="space-y-2">
            <Label htmlFor="userCode" className="text-foreground">
              Device code
            </Label>
            <Input
              id="userCode"
              placeholder="XXXX-XXXX"
              value={code}
              autoFocus
              onChange={(e) => setCode(normalizeUserCode(e.target.value))}
              className="bg-background border-border text-foreground font-mono text-lg tracking-widest text-center"
              maxLength={9}
            />
          </div>
          {pending.isError && (
            <p className="text-sm text-red-600">
              That code wasn&apos;t recognized. It may have expired — run{" "}
              <code className="font-mono">strato login</code> again for a fresh
              code.
            </p>
          )}
          <Button
            type="submit"
            className="w-full bg-primary hover:bg-primary/90"
            disabled={pending.isLoading}
          >
            {pending.isLoading ? (
              <Loader2 className="h-4 w-4 animate-spin" />
            ) : (
              "Continue"
            )}
          </Button>
        </form>
      </CardContent>
    </Card>
  );
}

export default function ActivatePage() {
  return (
    <div className="max-w-7xl mx-auto pt-8">
      <Suspense fallback={null}>
        <ActivateForm />
      </Suspense>
    </div>
  );
}
