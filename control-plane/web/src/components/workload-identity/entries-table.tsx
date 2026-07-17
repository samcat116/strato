"use client";

import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { Skeleton } from "@/components/ui/skeleton";
import { CopyButton } from "@/components/ui/copy-button";
import type { WorkloadRegistrationEntry } from "@/types/api";
import { SVIDBadge } from "./svid-badge";
import { formatRelative, formatTTL } from "./format";

interface EntriesTableProps {
  entries: WorkloadRegistrationEntry[];
  isLoading?: boolean;
  /** Whether any filter is active — changes the empty-state copy. */
  filtered?: boolean;
}

export function EntriesTable({ entries, isLoading, filtered }: EntriesTableProps) {
  if (isLoading) {
    return (
      <div className="space-y-2 p-2">
        {[...Array(6)].map((_, i) => (
          <Skeleton key={i} className="h-11 w-full bg-muted" />
        ))}
      </div>
    );
  }

  if (entries.length === 0) {
    return (
      <div className="text-center py-12 text-muted-foreground">
        {filtered
          ? "No entries match the current filters."
          : "No registration entries. Workloads appear here once SPIRE issues their identities."}
      </div>
    );
  }

  return (
    <Table>
      <TableHeader className="bg-background">
        <TableRow className="border-border hover:bg-transparent">
          <TableHead className="text-muted-foreground font-medium">SPIFFE ID</TableHead>
          <TableHead className="text-muted-foreground font-medium">Selectors</TableHead>
          <TableHead className="text-muted-foreground font-medium">SVID</TableHead>
          <TableHead className="text-muted-foreground font-medium">TTL</TableHead>
          <TableHead className="text-muted-foreground font-medium">Expires</TableHead>
          <TableHead className="text-muted-foreground font-medium">Node</TableHead>
          <TableHead className="w-0">
            <span className="sr-only">Actions</span>
          </TableHead>
        </TableRow>
      </TableHeader>
      <TableBody className="divide-y divide-border">
        {entries.map((entry) => {
          const trimmedPath = entry.path.replace(/^\//, "");
          return (
            <TableRow key={entry.id} className="border-border hover:bg-accent/60">
              <TableCell className="max-w-[240px]">
                <div className="flex items-center gap-2">
                  <span className="h-2 w-2 shrink-0 rounded-full bg-green-500" aria-hidden />
                  <span
                    className="truncate font-mono text-[13px] font-medium text-foreground"
                    title={entry.spiffeID}
                  >
                    <span className="text-muted-foreground/60">…/</span>
                    {trimmedPath}
                  </span>
                  {entry.admin && (
                    <Badge
                      variant="outline"
                      className="border-amber-500/40 text-amber-600 dark:text-amber-400 text-[10px] px-1.5 py-0"
                    >
                      admin
                    </Badge>
                  )}
                </div>
              </TableCell>
              <TableCell className="max-w-[220px]">
                <span
                  className="truncate block font-mono text-xs text-muted-foreground"
                  title={entry.selectors.join(", ")}
                >
                  {entry.selectors.length > 0 ? entry.selectors.join(", ") : "—"}
                </span>
              </TableCell>
              <TableCell>
                <div className="flex gap-1">
                  {entry.svidTypes.map((type) => (
                    <SVIDBadge key={type} type={type} />
                  ))}
                </div>
              </TableCell>
              <TableCell className="font-mono text-xs text-foreground/80">
                {formatTTL(entry.x509TTLSeconds)}
              </TableCell>
              <TableCell className="font-mono text-xs text-muted-foreground">
                {entry.expiresAt ? formatRelative(entry.expiresAt) : "—"}
              </TableCell>
              <TableCell className="font-mono text-xs text-foreground/80">
                {entry.node ?? "—"}
              </TableCell>
              <TableCell className="text-right">
                <CopyButton
                  value={entry.spiffeID}
                  label="Copy SPIFFE ID"
                  toastMessage="SPIFFE ID copied"
                />
              </TableCell>
            </TableRow>
          );
        })}
      </TableBody>
    </Table>
  );
}
