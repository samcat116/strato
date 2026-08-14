"use client";

import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Trash2 } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { QueryErrorNotice } from "@/components/ui/query-error-notice";
import { workloadRegistrationsApi } from "@/lib/api/platform-services";
import { workloadRegistrationDeletionMessage } from "@/lib/workload-registration";
import { useOrganization } from "@/providers";

export function WorkloadRegistrationManager() {
  const { currentOrg } = useOrganization();
  const queryClient = useQueryClient();
  const [spiffeId, setSpiffeId] = useState("");
  const [displayName, setDisplayName] = useState("");
  const query = useQuery({
    queryKey: ["workload-registrations"],
    queryFn: ({ signal }) => workloadRegistrationsApi.list(signal),
  });
  const refresh = () => {
    void queryClient.invalidateQueries({ queryKey: ["workload-registrations"] });
    void queryClient.invalidateQueries({ queryKey: ["workload-identity"] });
  };
  const create = useMutation({
    mutationFn: () =>
      workloadRegistrationsApi.create({
        spiffeId,
        organizationId: currentOrg!.id,
        displayName: displayName || undefined,
      }),
    onSuccess: () => {
      setSpiffeId("");
      setDisplayName("");
      refresh();
      toast.success("Workload identity registered");
    },
    onError: (error) => toast.error(error.message),
  });
  const remove = useMutation({
    mutationFn: workloadRegistrationsApi.delete,
    onSuccess: refresh,
    onError: (error) => toast.error(error.message),
  });

  return (
    <Card>
      <CardHeader><CardTitle>Workload registry</CardTitle></CardHeader>
      <CardContent className="space-y-4">
        <QueryErrorNotice resource="workload registrations" error={query.error} hasData={query.data !== undefined} onRetry={() => void query.refetch()} />
        {currentOrg && <form className="grid gap-3 md:grid-cols-[2fr_1fr_auto]" onSubmit={(event) => { event.preventDefault(); create.mutate(); }}><div><Label htmlFor="registration-spiffe-id">SPIFFE ID</Label><Input id="registration-spiffe-id" value={spiffeId} onChange={(event) => setSpiffeId(event.target.value)} placeholder="spiffe://example.org/workload/api" required /></div><div><Label htmlFor="registration-name">Display name</Label><Input id="registration-name" value={displayName} onChange={(event) => setDisplayName(event.target.value)} /></div><Button className="self-end" disabled={create.isPending}>Register</Button></form>}
        <div className="max-h-96 divide-y overflow-auto rounded-lg border">
          {(query.data ?? []).map((registration) => (
            <div
              key={registration.id}
              className="flex items-center justify-between gap-4 p-3"
            >
              <div className="min-w-0">
                <p className="truncate font-mono text-sm">
                  {registration.spiffeId}
                </p>
                <p className="text-xs text-muted-foreground">
                  {registration.kind} · {registration.displayName ??
                    registration.agentName ??
                    "Unlabelled"}
                </p>
              </div>
              <Button
                variant="ghost"
                size="icon"
                aria-label={`Delete registration ${registration.spiffeId}`}
                disabled={remove.isPending}
                onClick={() => {
                  if (
                    window.confirm(
                      workloadRegistrationDeletionMessage(registration)
                    )
                  ) {
                    remove.mutate(registration.id);
                  }
                }}
              >
                <Trash2 className="h-4 w-4" />
              </Button>
            </div>
          ))}
        </div>
      </CardContent>
    </Card>
  );
}
