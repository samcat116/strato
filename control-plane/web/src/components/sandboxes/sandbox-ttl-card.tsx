"use client";

import { Timer } from "lucide-react";
import { useEffect, useState } from "react";

import { StatCard } from "@/components/ui/detail-page-shell";

import { formatDuration, formatRemaining } from "./format";

interface SandboxTtlCardProps {
  /** The idle budget, or null for a sandbox that never expires. */
  ttlSeconds?: number | null;
  /** When the budget runs out; extended server-side by admitted activity. */
  expiresAt?: string | null;
}

/** Activity extends this deadline; reaching it is not a deletion verdict. */
export function SandboxTtlCard({ ttlSeconds, expiresAt }: SandboxTtlCardProps) {
  const [now, setNow] = useState(() => Date.now());

  useEffect(() => {
    if (!expiresAt) return;
    const id = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(id);
  }, [expiresAt]);

  return (
    <StatCard title="Idle TTL" icon={<Timer className="h-4 w-4" />}>
      <TtlValue ttlSeconds={ttlSeconds} expiresAt={expiresAt} now={now} />
    </StatCard>
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
        <div className="text-xl font-bold text-red-600">Idle deadline reached</div>
        <p className="text-sm text-muted-foreground">Active or unknown activity can defer cleanup</p>
      </>
    );
  }

  return (
    <>
      <div className="text-xl font-bold text-foreground">{remaining}</div>
      <p className="text-sm text-muted-foreground">
        of {formatDuration(ttlSeconds)} idle budget remaining
      </p>
    </>
  );
}
