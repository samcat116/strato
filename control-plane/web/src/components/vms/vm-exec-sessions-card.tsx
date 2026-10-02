"use client";

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { api } from "@/lib/api/client";
import { usePermissions } from "@/lib/hooks";
import { formatDateTime } from "@/lib/format-time";
import type { components } from "@/types/openapi";

type LiveSession = components["schemas"]["LiveVMExecSession"];

export function VMExecSessionsCard({ vmId }: { vmId: string }) {
  const queryClient = useQueryClient();
  const queryKey = ["vms", vmId, "exec-sessions"];
  const { permissions } = usePermissions([
    { key: "terminate", action: "vm:exec", node: { type: "virtual_machine", id: vmId } },
  ]);
  const sessions = useQuery({
    queryKey,
    queryFn: ({ signal }) => api.get<LiveSession[]>(`/api/vms/${vmId}/exec-sessions`, undefined, signal),
    refetchInterval: 5000,
  });
  const terminate = useMutation({
    mutationFn: (sessionId: string) => api.post(`/api/vms/${vmId}/exec-sessions/${sessionId}/terminate`),
    onSuccess: () => {
      toast.success("Session termination requested");
      void queryClient.invalidateQueries({ queryKey });
    },
    onError: () => toast.error("Could not terminate session"),
  });
  return (
    <Card>
      <CardHeader><CardTitle>Live exec sessions</CardTitle></CardHeader>
      <CardContent className="space-y-3 text-sm">
        {sessions.isLoading && <p>Loading sessions...</p>}
        {sessions.error ? <p role="alert">Could not load live sessions. <Button variant="link" onClick={() => void sessions.refetch()}>Retry</Button></p> : (
          <>
            {sessions.data?.length === 0 && <p>No attached sessions.</p>}
            {sessions.data?.map((session) => (
              <div key={session.sessionId} className="flex items-center justify-between gap-4">
                <div>
                  <p>{session.username || session.userId}</p>
                  <p className="text-xs text-muted-foreground">Attached {formatDateTime(session.attachedAt)}</p>
                  {session.terminationRequested && <p>Termination pending</p>}
                </div>
                {permissions.terminate && <Button variant="destructive" size="sm" disabled={terminate.isPending || session.terminationRequested} onClick={() => terminate.mutate(session.sessionId)}>Terminate</Button>}
              </div>
            ))}
          </>
        )}
        <p className="text-xs text-muted-foreground">Interactive sessions update every five seconds. Abandoned sessions close after 15 minutes without input or resize. Recorded commands appear in operation history.</p>
      </CardContent>
    </Card>
  );
}
