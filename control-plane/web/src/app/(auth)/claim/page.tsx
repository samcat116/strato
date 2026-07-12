"use client";

import { Suspense, useEffect, useState } from "react";
import { useSearchParams } from "next/navigation";
import Link from "next/link";
import {
  CheckCircle2,
  KeyRound,
  Loader2,
  ShieldAlert,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Card,
  CardContent,
  CardDescription,
  CardFooter,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { authApi } from "@/lib/api/auth";
import { WebAuthnClient, webAuthnClient } from "@/lib/webauthn/client";
import { toast } from "sonner";
import type { ClaimInfoResponse } from "@/types/api";

export default function ClaimPage() {
  return (
    <div className="min-h-screen flex items-center justify-center p-4">
      <Suspense
        fallback={
          <div className="text-muted-foreground">Loading...</div>
        }
      >
        <ClaimCard />
      </Suspense>
    </div>
  );
}

type Phase = "loading" | "ready" | "invalid" | "enrolling" | "complete";

function ClaimCard() {
  const searchParams = useSearchParams();
  const token = searchParams.get("token") ?? "";

  // Derive the missing-token case from initial state so the effect never calls
  // setState synchronously (react-hooks/set-state-in-effect).
  const [phase, setPhase] = useState<Phase>(token ? "loading" : "invalid");
  const [info, setInfo] = useState<ClaimInfoResponse | null>(null);
  const [invalidReason, setInvalidReason] = useState<string>(
    token ? "" : "This invitation link is missing its token."
  );

  const webAuthnSupported = WebAuthnClient.isSupported();

  useEffect(() => {
    if (!token) return;
    let cancelled = false;

    (async () => {
      try {
        const result = await authApi.claimInfo(token);
        if (cancelled) return;
        setInfo(result);
        if (!result.valid) {
          setInvalidReason(
            result.alreadyClaimed
              ? "This invitation has already been used. Try signing in instead."
              : result.expired
                ? "This invitation link has expired. Ask an administrator for a new one."
                : "This invitation link is no longer valid."
          );
          setPhase("invalid");
        } else {
          setPhase("ready");
        }
      } catch {
        if (cancelled) return;
        setInvalidReason(
          "This invitation link is invalid. Ask an administrator for a new one."
        );
        setPhase("invalid");
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [token]);

  const handleEnroll = async () => {
    if (!webAuthnSupported) {
      toast.error("WebAuthn is not supported in this browser");
      return;
    }
    setPhase("enrolling");
    try {
      await webAuthnClient.claim(token);
      setPhase("complete");
      toast.success("Passkey set up successfully");
      // Full navigation so the auth provider re-reads the new session.
      setTimeout(() => {
        window.location.assign("/dashboard");
      }, 1200);
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : "Failed to set up passkey"
      );
      setPhase("ready");
    }
  };

  if (phase === "loading") {
    return (
      <Card className="w-full max-w-md bg-card border-border">
        <CardContent className="py-10 flex justify-center">
          <Loader2 className="h-6 w-6 animate-spin text-muted-foreground" />
        </CardContent>
      </Card>
    );
  }

  if (phase === "invalid") {
    return (
      <Card className="w-full max-w-md bg-card border-border">
        <CardHeader className="space-y-1">
          <div className="flex justify-center mb-2">
            <ShieldAlert className="h-10 w-10 text-muted-foreground" />
          </div>
          <CardTitle className="text-xl font-bold text-foreground text-center">
            Invitation unavailable
          </CardTitle>
          <CardDescription className="text-muted-foreground text-center">
            {invalidReason}
          </CardDescription>
        </CardHeader>
        <CardFooter className="flex justify-center">
          <Link href="/login" className="text-blue-600 hover:text-blue-700 text-sm">
            Go to sign in
          </Link>
        </CardFooter>
      </Card>
    );
  }

  return (
    <Card className="w-full max-w-md bg-card border-border">
      <CardHeader className="space-y-1">
        <CardTitle className="text-2xl font-bold text-foreground">
          Set up your passkey
        </CardTitle>
        <CardDescription className="text-muted-foreground">
          {phase === "complete"
            ? "You're all set"
            : "Finish activating your Strato account"}
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-4">
        {!webAuthnSupported && (
          <div className="p-3 bg-red-500/10 border border-red-300 rounded-md text-sm text-red-800">
            WebAuthn is not supported in this browser. Please use a modern
            browser with passkey support.
          </div>
        )}

        {phase === "complete" ? (
          <div className="text-center space-y-4">
            <div className="flex justify-center">
              <CheckCircle2 className="h-16 w-16 text-green-600" />
            </div>
            <p className="text-foreground/80">
              Welcome to Strato, <strong>{info?.displayName}</strong>!
            </p>
            <p className="text-sm text-muted-foreground">
              Redirecting to dashboard...
            </p>
          </div>
        ) : (
          <>
            <div className="p-4 bg-background rounded-lg border border-border">
              <p className="text-sm text-foreground/80 mb-2">
                You&apos;re activating the account for:
              </p>
              <p className="text-lg font-semibold text-foreground">
                {info?.displayName}
              </p>
              <p className="text-sm text-muted-foreground">@{info?.username}</p>
            </div>
            <p className="text-sm text-muted-foreground">
              Click below to create a passkey. You&apos;ll be prompted to use
              your device&apos;s biometric authentication (Face ID, Touch ID,
              Windows Hello) or a security key.
            </p>
            <Button
              type="button"
              className="w-full bg-primary hover:bg-primary/90"
              onClick={handleEnroll}
              disabled={phase === "enrolling" || !webAuthnSupported}
            >
              {phase === "enrolling" ? (
                <Loader2 className="h-4 w-4 mr-2 animate-spin" />
              ) : (
                <KeyRound className="h-4 w-4 mr-2" />
              )}
              Create Passkey
            </Button>
          </>
        )}
      </CardContent>
    </Card>
  );
}
