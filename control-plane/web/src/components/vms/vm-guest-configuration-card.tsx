"use client";

import { useState, type FormEvent } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogDescription } from "@/components/ui/dialog";
import { usePermissions } from "@/lib/hooks/use-permissions";
import { useAcceptedMutation } from "@/lib/hooks/use-accepted-mutation";
import { vmsApi } from "@/lib/api/vms";
import type { GuestConfig, VM } from "@/types/api";

const emptyConfig: GuestConfig = { packages: [], files: [], services: [], sysctls: [] };

export function VMGuestConfigurationCard({ vm }: { vm: VM }) {
  const { permissions } = usePermissions([
    { key: "configure", action: "vm:configureGuest", node: { type: "virtual_machine", id: vm.id } },
  ]);
  const queryClient = useQueryClient();
  const config = useQuery({
    queryKey: ["vm-guest-config", vm.id],
    queryFn: ({ signal }) => vmsApi.guestConfiguration(vm.id, signal),
    enabled: permissions.configure,
    refetchInterval: 5000,
  });
  const mutation = useAcceptedMutation();
  const [open, setOpen] = useState(false);
  const [text, setText] = useState("");
  const [error, setError] = useState<string | null>(null);
  const desired = config.data?.guestConfig;

  function beginEdit() {
    setText(JSON.stringify(desired ?? emptyConfig, null, 2));
    setError(null);
    setOpen(true);
  }

  function refresh() {
    void queryClient.invalidateQueries({ queryKey: ["vm-guest-config", vm.id] });
    void queryClient.invalidateQueries({ queryKey: ["vms", vm.id] });
    setOpen(false);
  }

  async function submit(event: FormEvent) {
    event.preventDefault();
    setError(null);
    let guestConfig: GuestConfig | null;
    try {
      guestConfig = JSON.parse(text) as GuestConfig | null;
    } catch {
      setError("Enter valid JSON. Packages, files, services and sysctls arrays are required.");
      return;
    }
    // Preserve the exact body on ambiguous retries. Do not copy it into toast
    // text or logs; file contents are visible only inside the privileged editor.
    const body = { guestConfig };
    await replace(body);
  }

  async function replace(body: { guestConfig: GuestConfig | null; retry?: boolean }) {
    await mutation.run({
      intentKey: `PUT:/api/vms/${vm.id}/guest-config:${JSON.stringify(body)}`,
      request: (key) => vmsApi.replaceGuestConfiguration(vm.id, body, key),
      watch: { kind: "guest_config", resourceKind: "virtual_machine", resourceName: vm.name, operation: true },
      errorMessage: "Unable to update guest configuration",
      onSuccess: refresh,
      onUnchanged: refresh,
      onError: (message) => { setError(message); return true; },
    });
  }

  return <Card>
    <CardHeader className="flex flex-row justify-between items-center">
      <CardTitle>Guest configuration</CardTitle>
      {permissions.configure && <Button variant="outline" onClick={beginEdit}
        disabled={!vm.guestAgentEnabled || !config.data || mutation.isLoading}>Edit configuration</Button>}
      {permissions.configure && config.data?.status === "failed" && <Button
        disabled={mutation.isLoading} onClick={() => {
          setError(null);
          void replace({ guestConfig: desired ?? null, retry: true });
        }}>Retry failed generation</Button>}
    </CardHeader>
    <CardContent className="space-y-3">
      {!vm.guestAgentEnabled && <p>The guest agent was not enabled for this VM.</p>}
      {!permissions.configure && <p>A deliberate guest-configuration grant is required to read or edit desired configuration.</p>}
      {config.isLoading && permissions.configure && <p>Loading desired configuration…</p>}
      {config.isError && <p role="alert">Unable to load desired configuration.</p>}
      {permissions.configure && config.data && <>
        <p>Desired generation {config.data.desiredGeneration}</p>
        <p>Guest configuration: {config.data.status}</p>
        {config.data.observedGeneration != null && <p>Observed generation {config.data.observedGeneration}</p>}
        {config.data.reportReceivedAt && <p>Report received {new Date(config.data.reportReceivedAt).toLocaleString()}</p>}
        {config.data.failureGeneration != null && config.data.failureGeneration !== config.data.desiredGeneration &&
          <p>Previous failure belongs to generation {config.data.failureGeneration}.</p>}
        {config.data.error && <p role="alert">{config.data.error}</p>}
        {!desired && <p>No guest items are managed.</p>}
        {(config.data.items ?? []).length > 0 && <table className="w-full text-sm text-left">
          <thead><tr><th>Item</th><th>Desired</th><th>Observed</th><th>State</th></tr></thead>
          <tbody>{config.data.items.map((item) => <tr key={`${item.section}:${item.identity}`}>
            <td className="break-all">{item.section}: {item.identity}</td>
            <td className="break-all">{item.desired}</td><td className="break-all">{item.observed ?? "Unknown"}</td>
            <td>{item.state}{item.error && <p>{item.error}</p>}</td>
          </tr>)}</tbody>
        </table>}
        {config.data.status === "deferred" && <p>Guest changes are deferred until this VM is running.</p>}
        {config.data.status === "stale" && <p>Retained observations are stale; they do not prove this generation converged.</p>}
        {config.data.status === "unavailable" && <p>Guest or node is unreachable. Last-known facts are not current proof.</p>}
        {(config.data.status === "pending" || !config.data.status) && <p>Awaiting current guest read-back. Desired state does not imply convergence.</p>}
      </>}
      {error && !open && <p role="alert">{error}</p>}
      <Dialog open={permissions.configure && open} onOpenChange={(value) => { if (!mutation.isLoading) setOpen(value); }}>
        <DialogContent>
          <DialogHeader><DialogTitle>Edit desired guest configuration</DialogTitle>
            <DialogDescription>Use packages, files, services and sysctls arrays. Services control boot enablement. Null, empty arrays and removed entries withdraw management without reversing guest changes.</DialogDescription>
          </DialogHeader>
          <form onSubmit={submit} className="space-y-4">
            <label htmlFor="guest-config-json">Configuration JSON</label>
            <textarea id="guest-config-json" value={text} onChange={(event) => setText(event.target.value)}
              disabled={mutation.isLoading} className="w-full min-h-64 font-mono text-sm border rounded p-2" />
            {error && <p role="alert">{error}</p>}
            <Button type="submit" disabled={mutation.isLoading}>Save desired configuration</Button>
          </form>
        </DialogContent>
      </Dialog>
    </CardContent>
  </Card>;
}
