"use client";

import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import type {
  FederationInfo,
  IssuanceInfo,
  NodeAttestationGroup,
  TrustBundleInfo,
} from "@/types/api";
import { formatRelative } from "./format";

const RAIL_TITLE = "text-xs font-semibold uppercase tracking-wide text-muted-foreground";

function Row({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div className="flex items-center justify-between font-mono text-xs">
      <span className="text-muted-foreground">{label}</span>
      <span className="text-foreground/80">{value}</span>
    </div>
  );
}

/** Trust domain + CA bundle metadata (real data from SPIREService). */
export function TrustBundleCard({
  trustDomain,
  trustBundle,
}: {
  trustDomain?: string;
  trustBundle?: TrustBundleInfo;
}) {
  return (
    <Card className="bg-card border-border">
      <CardHeader className="pb-3">
        <CardTitle className={RAIL_TITLE}>Trust domain &amp; bundle</CardTitle>
      </CardHeader>
      <CardContent className="space-y-2.5">
        <div className="font-mono text-sm font-semibold text-foreground break-all">
          {trustDomain ? `spiffe://${trustDomain}` : "—"}
        </div>
        {trustBundle ? (
          <div className="space-y-1.5 pt-1">
            <Row label="X.509 authorities" value={trustBundle.x509AuthorityCount} />
            <Row label="Bundle sequence" value={`#${trustBundle.sequenceNumber}`} />
            <Row label="Refreshed" value={formatRelative(trustBundle.refreshedAt)} />
          </div>
        ) : (
          <p className="text-xs text-muted-foreground pt-1">
            Trust bundle not yet loaded.
          </p>
        )}
      </CardContent>
    </Card>
  );
}

/** Attested nodes grouped by attestation method (real data). */
export function NodeAttestationCard({ groups }: { groups: NodeAttestationGroup[] }) {
  const total = groups.reduce((sum, g) => sum + g.count, 0);
  return (
    <Card className="bg-card border-border">
      <CardHeader className="pb-3 flex-row items-center justify-between space-y-0">
        <CardTitle className={RAIL_TITLE}>Node attestation</CardTitle>
        <span className="font-mono text-xs text-muted-foreground">{total} nodes</span>
      </CardHeader>
      <CardContent className="space-y-2">
        {groups.length === 0 ? (
          <p className="text-xs text-muted-foreground">No attested nodes.</p>
        ) : (
          groups.map((group) => (
            <div
              key={group.attestationType}
              className="flex items-center gap-2 font-mono text-xs text-foreground/80"
            >
              <span
                className={`h-1.5 w-1.5 rounded-full ${
                  group.banned > 0 ? "bg-amber-500" : "bg-green-500"
                }`}
                aria-hidden
              />
              <span className="text-foreground">{group.count}</span>
              <span className="text-muted-foreground">· {group.attestationType}</span>
              {group.banned > 0 && (
                <span className="text-red-600 dark:text-red-400">
                  ({group.banned} banned)
                </span>
              )}
            </div>
          ))
        )}
      </CardContent>
    </Card>
  );
}

/**
 * Federation relationships. When `available` is true these are the trust
 * domain's configured relationships with real sync state from SPIRE; when
 * false (unconfigured, or the trustdomain API was unreachable) the card
 * degrades to the domains entries federate with, shows a "Preview" badge, and
 * renders sync state as "unknown".
 */
export function FederationCard({ federation }: { federation: FederationInfo }) {
  const stateClass: Record<string, string> = {
    synced: "text-green-600 dark:text-green-400",
    refresh_failed: "text-red-600 dark:text-red-400",
    unknown: "text-muted-foreground",
  };
  return (
    <Card className="bg-card border-border">
      <CardHeader className="pb-3 flex-row items-center justify-between space-y-0">
        <CardTitle className={RAIL_TITLE}>Federation</CardTitle>
        {!federation.available && (
          <Badge
            variant="outline"
            className="text-[10px] px-1.5 py-0 border-border text-muted-foreground"
          >
            Preview
          </Badge>
        )}
      </CardHeader>
      <CardContent className="space-y-2">
        {federation.domains.length === 0 ? (
          <p className="text-xs text-muted-foreground">No federated trust domains.</p>
        ) : (
          federation.domains.map((domain) => (
            <div
              key={domain.trustDomain}
              className="flex items-center gap-2 font-mono text-xs"
            >
              <span className="h-1.5 w-1.5 rounded-full bg-muted-foreground/50" aria-hidden />
              <span className="flex-1 truncate text-foreground/80" title={domain.trustDomain}>
                {domain.trustDomain}
              </span>
              <span className={stateClass[domain.state] ?? "text-muted-foreground"}>
                {domain.state.replace("_", " ")}
              </span>
            </div>
          ))
        )}
        {!federation.available && federation.domains.length > 0 && (
          <p className="pt-1 text-[11px] text-muted-foreground">
            Relationship sync state is not yet reported.
          </p>
        )}
      </CardContent>
    </Card>
  );
}

/**
 * SVID issuance over a rolling window, read from the configured metrics store
 * (Prometheus). Shows a "Preview" badge and an unavailable state when no
 * metrics source is wired or a query failed.
 */
export function IssuanceCard({ issuance }: { issuance: IssuanceInfo }) {
  return (
    <Card className="bg-card border-border">
      <CardHeader className="pb-3 flex-row items-center justify-between space-y-0">
        <CardTitle className={RAIL_TITLE}>Issuance · {issuance.windowHours}h</CardTitle>
        {!issuance.available && (
          <Badge
            variant="outline"
            className="text-[10px] px-1.5 py-0 border-border text-muted-foreground"
          >
            Preview
          </Badge>
        )}
      </CardHeader>
      <CardContent>
        {issuance.available ? (
          <div className="space-y-3">
            <IssuanceBar label="X.509-SVID" value={issuance.x509SVIDs ?? 0} className="bg-blue-500" />
            <IssuanceBar label="JWT-SVID" value={issuance.jwtSVIDs ?? 0} className="bg-purple-500" />
          </div>
        ) : (
          <p className="text-xs text-muted-foreground">
            Issuance metrics are not yet collected for this trust domain.
          </p>
        )}
      </CardContent>
    </Card>
  );
}

function IssuanceBar({
  label,
  value,
  className,
}: {
  label: string;
  value: number;
  className: string;
}) {
  return (
    <div>
      <div className="mb-1 flex justify-between font-mono text-xs text-foreground/70">
        <span>{label}</span>
        <span>{value.toLocaleString()}</span>
      </div>
      <div className="h-1.5 overflow-hidden rounded bg-muted">
        <div className={`h-full rounded ${className}`} style={{ width: `${Math.min(value, 100)}%` }} />
      </div>
    </div>
  );
}
