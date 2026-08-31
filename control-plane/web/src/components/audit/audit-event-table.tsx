"use client";

import { KeyRound, ShieldAlert } from "lucide-react";
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
import type { AuditEvent } from "@/types/api";

interface AuditEventTableProps {
  events: AuditEvent[];
  isLoading?: boolean;
  /** Called when the user clicks an actor cell to filter by that user. */
  onFilterByUser?: (userID: string) => void;
  /** Called when the user clicks a VM resource cell. */
  onFilterByVM?: (vmID: string) => void;
}

const EXECUTION_EVENT_LABELS: Record<string, string> = {
  "vm.command.requested": "VM command requested",
  "vm.command.completed": "VM command completed",
  "vm.exec.requested": "VM exec requested",
  "vm.exec.started": "VM exec started",
  "vm.exec.ended": "VM exec ended",
};

function executionArguments(event: AuditEvent): string | undefined {
  const value = event.metadata?.argv;
  if (!value) return undefined;
  try {
    const parsed: unknown = JSON.parse(value);
    if (!Array.isArray(parsed) || !parsed.every((argument) => typeof argument === "string")) {
      return undefined;
    }
    return JSON.stringify(parsed);
  } catch {
    return undefined;
  }
}

function executionOutcomeClass(outcome: string): string {
  if (outcome === "exited" || outcome === "accepted" || outcome === "started") {
    return "bg-emerald-900/30 text-emerald-700 border-transparent";
  }
  if (outcome === "timed_out" || outcome === "terminated") {
    return "bg-amber-900/30 text-amber-700 border-transparent";
  }
  return "bg-red-900/40 text-red-700 border-transparent";
}

function statusBadgeClass(status: number): string {
  if (status >= 500) return "bg-red-900/40 text-red-700 border-transparent";
  if (status >= 400) return "bg-amber-900/30 text-amber-700 border-transparent";
  return "bg-emerald-900/30 text-emerald-700 border-transparent";
}

function formatTimestamp(value?: string): string {
  if (!value) return "—";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return date.toLocaleString(undefined, {
    year: "numeric",
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
}

/** "vm 4f2a…" when the event names a resource, otherwise the request line. */
function resourceLabel(event: AuditEvent): { text: string; title?: string } {
  if (event.resourceType) {
    const id = event.resourceID
      ? event.resourceID.length > 12
        ? `${event.resourceID.slice(0, 8)}…`
        : event.resourceID
      : "";
    return {
      text: `${event.resourceType} ${id}`.trim(),
      title: event.resourceID,
    };
  }
  if (event.method && event.path) {
    return { text: `${event.method} ${event.path}`, title: event.path };
  }
  return { text: event.action ?? "—" };
}

export function AuditEventTable({
  events,
  isLoading,
  onFilterByUser,
  onFilterByVM,
}: AuditEventTableProps) {
  if (isLoading) {
    return (
      <div className="space-y-2">
        {[...Array(5)].map((_, i) => (
          <Skeleton key={i} className="h-12 w-full bg-muted" />
        ))}
      </div>
    );
  }

  if (events.length === 0) {
    return (
      <div className="text-center py-8 text-muted-foreground">
        No audit events match the current filters.
      </div>
    );
  }

  return (
    <Table>
      <TableHeader className="bg-background">
        <TableRow className="border-border hover:bg-transparent">
          <TableHead className="text-muted-foreground font-medium">
            Timestamp
          </TableHead>
          <TableHead className="text-muted-foreground font-medium">
            Event
          </TableHead>
          <TableHead className="text-muted-foreground font-medium">
            Actor
          </TableHead>
          <TableHead className="text-muted-foreground font-medium">
            Resource
          </TableHead>
          <TableHead className="text-muted-foreground font-medium">
            Status
          </TableHead>
          <TableHead className="text-muted-foreground font-medium">
            Source IP
          </TableHead>
        </TableRow>
      </TableHeader>
      <TableBody className="divide-y divide-border">
        {events.map((event) => {
          const resource = resourceLabel(event);
          const actor = event.username ?? event.userID;
          const eventLabel = EXECUTION_EVENT_LABELS[event.eventType];
          const argv = eventLabel ? executionArguments(event) : undefined;
          const outcome = event.metadata?.outcome;
          return (
            <TableRow key={event.id} className="border-border hover:bg-accent/60">
              <TableCell className="text-muted-foreground text-sm whitespace-nowrap">
                {formatTimestamp(event.createdAt)}
              </TableCell>
              <TableCell>
                <div className="space-y-1 max-w-96">
                  <div className="flex items-center gap-2">
                    <span
                      className={
                        eventLabel
                          ? "text-sm text-foreground"
                          : "font-mono text-sm text-foreground"
                      }
                    >
                      {eventLabel ?? event.eventType}
                    </span>
                    {event.adminBypass && (
                      <Badge className="bg-purple-900/40 text-purple-700 border-transparent gap-1">
                        <ShieldAlert className="h-3 w-3" />
                        Admin bypass
                      </Badge>
                    )}
                  </div>
                  {eventLabel && (
                    <div className="font-mono text-xs text-muted-foreground">
                      {event.eventType}
                    </div>
                  )}
                  {eventLabel && (
                    <div
                      className="font-mono text-xs text-foreground/70 truncate"
                      title={argv}
                    >
                      {argv ?? "Arguments unavailable"}
                    </div>
                  )}
                  {eventLabel && (
                    <details className="text-xs text-muted-foreground">
                      <summary className="cursor-pointer hover:text-foreground">
                        Details
                      </summary>
                      <dl className="mt-1 grid grid-cols-[auto_1fr] gap-x-2 gap-y-0.5 font-mono break-all">
                        <dt>argv</dt>
                        <dd>{argv ?? "—"}</dd>
                        <dt>correlation</dt>
                        <dd>{event.metadata?.correlationID ?? "—"}</dd>
                        <dt>reason</dt>
                        <dd>{event.metadata?.reason ?? "—"}</dd>
                        <dt>phase</dt>
                        <dd>{event.metadata?.phase ?? "—"}</dd>
                        <dt>corrects</dt>
                        <dd>{event.metadata?.correctsOutcome ?? "—"}</dd>
                      </dl>
                    </details>
                  )}
                </div>
              </TableCell>
              <TableCell>
                {actor ? (
                  <span className="inline-flex items-center gap-1.5">
                    {onFilterByUser && event.userID ? (
                      <button
                        type="button"
                        className="text-foreground/80 hover:text-foreground hover:underline underline-offset-2"
                        onClick={() => onFilterByUser(event.userID!)}
                        title="Filter by this user"
                      >
                        {actor}
                      </button>
                    ) : (
                      <span className="text-foreground/80">{actor}</span>
                    )}
                    {event.apiKeyID && (
                      <KeyRound
                        className="h-3.5 w-3.5 text-muted-foreground"
                        aria-label="Authenticated with an API key"
                      />
                    )}
                  </span>
                ) : (
                  <span className="text-muted-foreground">—</span>
                )}
              </TableCell>
              <TableCell className="text-foreground/80 text-sm max-w-64 truncate">
                {onFilterByVM && event.resourceType === "vms" && event.resourceID ? (
                  <button
                    type="button"
                    className="hover:text-foreground hover:underline underline-offset-2"
                    title="Filter by this VM"
                    onClick={() => onFilterByVM(event.resourceID!)}
                  >
                    {resource.text}
                  </button>
                ) : (
                  <span title={resource.title}>{resource.text}</span>
                )}
              </TableCell>
              <TableCell>
                {outcome ? (
                  <div className="flex flex-wrap items-center gap-1">
                    <Badge className={executionOutcomeClass(outcome)}>{outcome}</Badge>
                    {event.metadata?.exitCode != null && (
                      <span className="font-mono text-xs text-muted-foreground">
                        exit {event.metadata.exitCode}
                      </span>
                    )}
                  </div>
                ) : event.status != null ? (
                  <Badge className={statusBadgeClass(event.status)}>
                    {event.status}
                  </Badge>
                ) : (
                  <span className="text-muted-foreground">—</span>
                )}
              </TableCell>
              <TableCell className="text-muted-foreground text-sm font-mono">
                {event.sourceIP ?? "—"}
              </TableCell>
            </TableRow>
          );
        })}
      </TableBody>
    </Table>
  );
}
