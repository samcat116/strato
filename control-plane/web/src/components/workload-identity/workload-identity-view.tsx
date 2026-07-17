"use client";

import { useMemo, useState } from "react";
import { AlertTriangle, Fingerprint } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import type { WorkloadIdentityOverview, WorkloadRegistrationEntry } from "@/types/api";
import { EntriesTable } from "./entries-table";
import {
  FederationCard,
  IssuanceCard,
  NodeAttestationCard,
  TrustBundleCard,
} from "./rail-cards";

// SPIRE issues both X.509 and JWT SVIDs for every entry, so filtering by SVID
// kind isn't meaningful — these filters partition entries by attributes that
// actually differ between them.
type Filter = "all" | "admin" | "federated" | "downstream";

const matchesFilter = (entry: WorkloadRegistrationEntry, filter: Filter): boolean => {
  switch (filter) {
    case "all":
      return true;
    case "admin":
      return entry.admin;
    case "federated":
      return entry.federatesWith.length > 0;
    case "downstream":
      return entry.downstream;
  }
};

interface WorkloadIdentityViewProps {
  data?: WorkloadIdentityOverview;
  isLoading?: boolean;
  /** Rendered message when the request failed outright. */
  errorMessage?: string;
}

/**
 * Presentational Workload Identity screen. Auth gating and data fetching live
 * in the page; this component is pure(-ish) over `data` so it can be rendered
 * against fixtures.
 */
export function WorkloadIdentityView({
  data,
  isLoading,
  errorMessage,
}: WorkloadIdentityViewProps) {
  const [filter, setFilter] = useState<Filter>("all");

  const entries = useMemo(() => data?.entries ?? [], [data]);
  const counts = useMemo(
    () => ({
      all: entries.length,
      admin: entries.filter((e) => e.admin).length,
      federated: entries.filter((e) => e.federatesWith.length > 0).length,
      downstream: entries.filter((e) => e.downstream).length,
    }),
    [entries]
  );
  const visibleEntries = useMemo(
    () => entries.filter((e) => matchesFilter(e, filter)),
    [entries, filter]
  );

  const nodesAttested = data?.nodeAttestation.reduce((sum, g) => sum + g.count, 0) ?? 0;

  return (
    <div className="max-w-7xl mx-auto space-y-6">
      {/* Header */}
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <div className="flex items-center gap-2.5">
            <h2 className="text-2xl font-semibold text-foreground">Workload Identity</h2>
            <Badge
              variant="outline"
              className="font-mono text-[10px] tracking-wide border-primary/30 text-primary bg-primary/5"
            >
              SPIFFE / SPIRE
            </Badge>
          </div>
          <div className="mt-1.5 flex flex-wrap items-center gap-x-3 gap-y-1 font-mono text-xs text-muted-foreground">
            {data?.trustDomain && (
              <>
                <span>
                  spiffe://<span className="text-foreground/80">{data.trustDomain}</span>
                </span>
                <span className="text-border">·</span>
              </>
            )}
            <span>
              <span className="text-foreground/80">{counts.all}</span> entries
            </span>
            <span className="text-border">·</span>
            <span>
              <span className="text-foreground/80">{nodesAttested}</span> nodes attested
            </span>
          </div>
        </div>
      </div>

      {errorMessage ? (
        <Card className="bg-card border-border">
          <CardContent className="py-10 text-center text-red-600">{errorMessage}</CardContent>
        </Card>
      ) : data && !data.enabled ? (
        <NotConfigured />
      ) : (
        <>
          {data?.warning && (
            <div className="flex items-start gap-2 rounded-lg border border-amber-500/30 bg-amber-500/10 px-4 py-3 text-sm text-amber-700 dark:text-amber-300">
              <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" />
              <span>{data.warning}</span>
            </div>
          )}

          <div className="flex flex-col gap-6 lg:flex-row lg:items-start">
            {/* Entries table + filters */}
            <div className="min-w-0 flex-1 space-y-4">
              <div className="flex flex-wrap gap-2">
                <FilterChip label="All" count={counts.all} active={filter === "all"} onClick={() => setFilter("all")} />
                <FilterChip label="Admin" count={counts.admin} dot="bg-amber-500" active={filter === "admin"} onClick={() => setFilter("admin")} />
                <FilterChip label="Federated" count={counts.federated} dot="bg-emerald-500" active={filter === "federated"} onClick={() => setFilter("federated")} />
                <FilterChip label="Downstream" count={counts.downstream} dot="bg-blue-500" active={filter === "downstream"} onClick={() => setFilter("downstream")} />
              </div>

              <Card className="bg-card border-border overflow-hidden py-0">
                <EntriesTable
                  entries={visibleEntries}
                  isLoading={isLoading}
                  filtered={filter !== "all"}
                />
                {!isLoading && entries.length > 0 && (
                  <div className="border-t border-border px-4 py-2.5 font-mono text-xs text-muted-foreground">
                    {visibleEntries.length} of {counts.all} entries
                  </div>
                )}
              </Card>
            </div>

            {/* Rail */}
            <aside className="w-full space-y-4 lg:w-[320px] lg:shrink-0">
              <TrustBundleCard trustDomain={data?.trustDomain} trustBundle={data?.trustBundle} />
              {data && <FederationCard federation={data.federation} />}
              <NodeAttestationCard groups={data?.nodeAttestation ?? []} />
              {data && <IssuanceCard issuance={data.issuance} />}
            </aside>
          </div>
        </>
      )}
    </div>
  );
}

function FilterChip({
  label,
  count,
  dot,
  active,
  onClick,
}: {
  label: string;
  count: number;
  dot?: string;
  active: boolean;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={`flex items-center gap-1.5 rounded-full border px-3 py-1 text-xs transition-colors ${
        active
          ? "border-foreground bg-foreground font-medium text-background"
          : "border-border bg-card text-muted-foreground hover:border-foreground/30"
      }`}
    >
      {dot && <span className={`h-1.5 w-1.5 rounded-full ${dot}`} aria-hidden />}
      {label} {count}
    </button>
  );
}

function NotConfigured() {
  return (
    <Card className="bg-card border-border">
      <CardHeader>
        <CardTitle className="flex items-center gap-2 text-lg font-semibold text-foreground">
          <Fingerprint className="h-5 w-5 text-muted-foreground" />
          SPIRE is not configured
        </CardTitle>
      </CardHeader>
      <CardContent className="space-y-3 text-sm text-muted-foreground">
        <p>
          Workload identity (SPIFFE / SPIRE) is not enabled on this control plane. Once a SPIRE
          server is configured, registration entries, attested nodes, and the trust bundle will
          appear here.
        </p>
        <p className="font-mono text-xs">
          Enable it by setting <span className="text-foreground/80">SPIRE_ENABLED=true</span> and{" "}
          <span className="text-foreground/80">SPIRE_SERVER_API_ADDRESS</span>, or run{" "}
          <span className="text-foreground/80">task dev-spiffe</span> locally.
        </p>
      </CardContent>
    </Card>
  );
}
