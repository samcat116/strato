"use client";

import { useMemo, useState } from "react";
import { ChevronLeft, ChevronRight, ShieldAlert, X } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Skeleton } from "@/components/ui/skeleton";
import { AuditEventTable } from "@/components/audit/audit-event-table";
import { auditErrorMessage, useAuditEvents } from "@/lib/hooks/use-audit-events";
import { useAuth } from "@/providers";

const PAGE_SIZE = 50;

// Mirrors AuditEventType in the control plane's AuditService.swift.
const EVENT_TYPES = [
  { value: "api.request", label: "API request" },
  { value: "auth.login", label: "Login" },
  { value: "auth.login_failed", label: "Login failed" },
  { value: "auth.logout", label: "Logout" },
  { value: "auth.register", label: "Registration" },
  { value: "auth.oidc_login", label: "OIDC login" },
  { value: "auth.oidc_login_failed", label: "OIDC login failed" },
];

const ALL_EVENT_TYPES = "all";

/** datetime-local input value → ISO8601 UTC for the API, or undefined. */
function toISO(local: string): string | undefined {
  if (!local) return undefined;
  const date = new Date(local);
  return Number.isNaN(date.getTime()) ? undefined : date.toISOString();
}

export default function AdminAuditPage() {
  const { user, isLoading: isAuthLoading } = useAuth();
  const isSystemAdmin = !!user?.isSystemAdmin;

  const [eventType, setEventType] = useState(ALL_EVENT_TYPES);
  const [adminOnly, setAdminOnly] = useState(false);
  const [fromLocal, setFromLocal] = useState("");
  const [toLocal, setToLocal] = useState("");
  const [userID, setUserID] = useState<string | undefined>(undefined);
  const [offset, setOffset] = useState(0);

  const filters = useMemo(
    () => ({
      eventType: eventType === ALL_EVENT_TYPES ? undefined : eventType,
      adminOnly: adminOnly || undefined,
      from: toISO(fromLocal),
      to: toISO(toLocal),
      userID,
      limit: PAGE_SIZE,
      offset,
    }),
    [eventType, adminOnly, fromLocal, toLocal, userID, offset]
  );

  const { data, isLoading, isPlaceholderData, error } = useAuditEvents(
    filters,
    isSystemAdmin
  );

  const events = data?.events ?? [];
  const total = data?.total ?? 0;
  const hasFilters =
    eventType !== ALL_EVENT_TYPES || adminOnly || !!fromLocal || !!toLocal || !!userID;

  const clearFilters = () => {
    setEventType(ALL_EVENT_TYPES);
    setAdminOnly(false);
    setFromLocal("");
    setToLocal("");
    setUserID(undefined);
    setOffset(0);
  };

  if (isAuthLoading) {
    return (
      <div className="max-w-6xl mx-auto space-y-6">
        <Skeleton className="h-8 w-64 bg-muted" />
        <Skeleton className="h-64 w-full bg-muted" />
      </div>
    );
  }

  if (!isSystemAdmin) {
    return (
      <div className="max-w-6xl mx-auto">
        <div className="text-center py-12">
          <ShieldAlert className="h-10 w-10 mx-auto mb-4 text-muted-foreground" />
          <p className="text-muted-foreground">
            You need system administrator rights to view the audit log.
          </p>
        </div>
      </div>
    );
  }

  return (
    <div className="max-w-6xl mx-auto space-y-6">
      {/* Header */}
      <div>
        <h2 className="text-2xl font-semibold text-foreground">Audit Log</h2>
        <p className="text-muted-foreground">
          Authentication and API activity across this Strato installation
        </p>
      </div>

      <Card className="bg-card border-border">
        <CardHeader>
          <CardTitle className="text-lg font-semibold text-foreground">
            Events
          </CardTitle>
        </CardHeader>
        <CardContent className="space-y-4">
          {/* Filters */}
          <div className="flex flex-wrap items-end gap-3">
            <div className="space-y-1.5">
              <Label htmlFor="auditEventType" className="text-muted-foreground">
                Event type
              </Label>
              <Select
                value={eventType}
                onValueChange={(value) => {
                  setEventType(value);
                  setOffset(0);
                }}
              >
                <SelectTrigger
                  id="auditEventType"
                  className="w-48 bg-background border-border text-foreground"
                >
                  <SelectValue />
                </SelectTrigger>
                <SelectContent className="bg-card border-border">
                  <SelectItem
                    value={ALL_EVENT_TYPES}
                    className="text-foreground focus:bg-accent focus:text-accent-foreground"
                  >
                    All event types
                  </SelectItem>
                  {EVENT_TYPES.map((type) => (
                    <SelectItem
                      key={type.value}
                      value={type.value}
                      className="text-foreground focus:bg-accent focus:text-accent-foreground"
                    >
                      {type.label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>

            <div className="space-y-1.5">
              <Label htmlFor="auditFrom" className="text-muted-foreground">
                From
              </Label>
              <Input
                id="auditFrom"
                type="datetime-local"
                value={fromLocal}
                onChange={(e) => {
                  setFromLocal(e.target.value);
                  setOffset(0);
                }}
                className="bg-background border-border text-foreground"
              />
            </div>

            <div className="space-y-1.5">
              <Label htmlFor="auditTo" className="text-muted-foreground">
                To
              </Label>
              <Input
                id="auditTo"
                type="datetime-local"
                value={toLocal}
                onChange={(e) => {
                  setToLocal(e.target.value);
                  setOffset(0);
                }}
                className="bg-background border-border text-foreground"
              />
            </div>

            <Button
              variant={adminOnly ? "default" : "outline"}
              className={adminOnly ? "" : "border-input text-foreground"}
              onClick={() => {
                setAdminOnly((v) => !v);
                setOffset(0);
              }}
            >
              <ShieldAlert className="h-4 w-4" />
              Admin bypass only
            </Button>

            {userID && (
              <Badge
                variant="secondary"
                className="h-9 px-3 bg-muted text-foreground/80 gap-1.5"
              >
                User: {userID.slice(0, 8)}…
                <button
                  type="button"
                  aria-label="Clear user filter"
                  onClick={() => {
                    setUserID(undefined);
                    setOffset(0);
                  }}
                  className="hover:text-foreground"
                >
                  <X className="h-3.5 w-3.5" />
                </button>
              </Badge>
            )}

            {hasFilters && (
              <Button
                variant="ghost"
                className="text-muted-foreground hover:text-foreground"
                onClick={clearFilters}
              >
                Clear filters
              </Button>
            )}
          </div>

          {error ? (
            <div className="text-center py-8 text-red-600">
              {auditErrorMessage(error, "Failed to load audit events")}
            </div>
          ) : (
            <AuditEventTable
              events={events}
              isLoading={isLoading}
              onFilterByUser={(id) => {
                setUserID(id);
                setOffset(0);
              }}
            />
          )}

          {/* Pagination */}
          {total > 0 && (
            <div className="flex items-center justify-between pt-2">
              <p className="text-sm text-muted-foreground">
                Showing {Math.min(offset + 1, total).toLocaleString()}–
                {Math.min(offset + events.length, total).toLocaleString()} of{" "}
                {total.toLocaleString()} events
              </p>
              <div className="flex items-center gap-2">
                <Button
                  variant="outline"
                  size="sm"
                  className="border-input text-foreground"
                  disabled={offset === 0 || isPlaceholderData}
                  onClick={() => setOffset(Math.max(0, offset - PAGE_SIZE))}
                >
                  <ChevronLeft className="h-4 w-4" />
                  Previous
                </Button>
                <Button
                  variant="outline"
                  size="sm"
                  className="border-input text-foreground"
                  disabled={offset + PAGE_SIZE >= total || isPlaceholderData}
                  onClick={() => setOffset(offset + PAGE_SIZE)}
                >
                  Next
                  <ChevronRight className="h-4 w-4" />
                </Button>
              </div>
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
