"use client";

import { Timer } from "lucide-react";
import { useEffect, useState } from "react";

import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";

import { formatDuration, formatRemaining } from "./format";

interface SandboxTtlCardProps {
  /** The lifetime budget, or null for a sandbox that never expires. */
  ttlSeconds?: number | null;
  /** When the budget runs out; derived server-side from the creation anchor. */
  expiresAt?: string | null;
}

/**
 * The sandbox's lifetime budget as a live countdown. The control plane's expiry
 * sweep deletes the sandbox once `expiresAt` passes, but it runs on a periodic
 * tick — so reaching zero means deletion is imminent, not already done, which
 * is why the elapsed state reads as awaiting cleanup rather than deleted.
 */
export function SandboxTtlCard({ ttlSeconds, expiresAt }: SandboxTtlCardProps) {
  const [now, setNow] = useState(() => Date.now());

  useEffect(() => {
    if (!expiresAt) return;
    const id = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(id);
  }, [expiresAt]);

  return (
    <Card className="bg-card border-border">
      <CardHeader className="pb-2">
        <CardTitle className="text-sm font-medium text-muted-foreground flex items-center gap-2">
          <Timer className="h-4 w-4" />
          TTL
        </CardTitle>
      </CardHeader>
      <CardContent>
        <TtlValue ttlSeconds={ttlSeconds} expiresAt={expiresAt} now={now} />
      </CardContent>
    </Card>
  );
}

function TtlValue({
  ttlSeconds,
  expiresAt,
  now,
}: SandboxTtlCardProps & { now: number }) {
  if (ttlSeconds == null) {
    return <div className="text-xl font-bold text-foreground">—</div>;
  }

  // A TTL with no expiry date means the server had no anchor to derive one
  // from; show the budget itself rather than an unfounded countdown.
  if (!expiresAt) {
    return (
      <div className="text-xl font-bold text-foreground">
        {formatDuration(ttlSeconds)}
      </div>
    );
  }

  const remaining = formatRemaining(expiresAt, now);
  if (remaining === null) {
    return (
      <>
        <div className="text-xl font-bold text-red-600">Expired</div>
        <p className="text-sm text-muted-foreground">Awaiting cleanup</p>
      </>
    );
  }

  return (
    <>
      <div className="text-xl font-bold text-foreground">{remaining}</div>
      <p className="text-sm text-muted-foreground">
        of {formatDuration(ttlSeconds)} left
      </p>
    </>
  );
}
