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
          return (
            <TableRow key={event.id} className="border-border hover:bg-accent/60">
              <TableCell className="text-muted-foreground text-sm whitespace-nowrap">
                {formatTimestamp(event.createdAt)}
              </TableCell>
              <TableCell>
                <div className="flex items-center gap-2">
                  <span className="font-mono text-sm text-foreground">
                    {event.eventType}
                  </span>
                  {event.adminBypass && (
                    <Badge className="bg-purple-900/40 text-purple-700 border-transparent gap-1">
                      <ShieldAlert className="h-3 w-3" />
                      Admin bypass
                    </Badge>
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
              <TableCell
                className="text-foreground/80 text-sm max-w-64 truncate"
                title={resource.title}
              >
                {resource.text}
              </TableCell>
              <TableCell>
                {event.status != null ? (
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
