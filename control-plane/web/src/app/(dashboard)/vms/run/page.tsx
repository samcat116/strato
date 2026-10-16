"use client";

import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { apiClient } from "@/lib/api/client";
import type { components } from "@/types/openapi";

type Fleet = components["schemas"]["VMFleetRun"];
type Operation = components["schemas"]["ResourceOperation"];

export default function FleetRunPage() {
  const [selector, setSelector] = useState("");
  const [argv, setArgv] = useState('["/usr/bin/id"]');
  const [preview, setPreview] = useState<Fleet>();
  const [runID, setRunID] = useState("");
  const [resumeID, setResumeID] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [fullOutput, setFullOutput] = useState<Record<string, Operation>>({});
  const result = useQuery({
    queryKey: ["vm-fleet-run", runID],
    enabled: !!runID,
    queryFn: () => apiClient<Fleet>(`/api/vm-fleet-runs/${encodeURIComponent(runID)}`),
    refetchInterval: (query) => query.state.data?.complete ? false : 2000,
  });
  const fleet = runID ? result.data : preview;

  async function resolve() {
    setBusy(true); setError(""); setPreview(undefined); setRunID("");
    try {
      const command: unknown = JSON.parse(argv);
      if (!Array.isArray(command) || !command.length || !command.every((value) => typeof value === "string")) {
        throw new Error("Enter a non-empty JSON array of command arguments.");
      }
      setPreview(await apiClient<Fleet>("/api/vm-fleet-runs", {
        method: "POST", body: JSON.stringify({ selector, command }),
      }));
    } catch (cause) { setError(cause instanceof Error ? cause.message : "Could not resolve selector."); }
    finally { setBusy(false); }
  }

  async function confirm() {
    const candidate = preview ?? result.data;
    if (!candidate || candidate.confirmed) return;
    setBusy(true); setError("");
    try {
      const accepted = await apiClient<Fleet>(`/api/vm-fleet-runs/${candidate.id}/confirm`, {
        method: "POST", body: JSON.stringify({ vmIDs: candidate.entries.map((entry) => entry.vmID) }),
      });
      setPreview(undefined); setRunID(accepted.id); setResumeID(accepted.id);
    } catch (cause) { setError(cause instanceof Error ? cause.message : "Could not confirm fleet run."); }
    finally { setBusy(false); }
  }

  return <div className="max-w-5xl mx-auto space-y-6">
    <h1 className="text-2xl font-semibold">Fleet command</h1>
    <p>Run one recorded command across up to 100 VMs. Review the exact command and targets before confirming. Accepted commands continue if you leave this page.</p>
    <label className="block space-y-2">Selector
      <Input aria-label="Selector" value={selector} onChange={(event) => { setSelector(event.target.value); setPreview(undefined); }}
        placeholder="project=<uuid>,environment=production,tag:role=web" />
    </label>
    <p className="text-sm text-muted-foreground">Use a project with optional environment and tag filters, or ids=&lt;uuid;uuid&gt; for an explicit list.</p>
    <label className="block space-y-2">Command arguments (JSON array)
      <Input aria-label="Command arguments" value={argv} onChange={(event) => { setArgv(event.target.value); setPreview(undefined); }} />
    </label>
    <Button onClick={resolve} disabled={busy}>Resolve targets</Button>
    <div className="flex gap-2">
      <Input aria-label="Saved fleet run ID" value={resumeID} onChange={(event) => setResumeID(event.target.value)} placeholder="Saved fleet run ID" />
      <Button variant="outline" disabled={busy || !resumeID} onClick={() => { setPreview(undefined); setRunID(resumeID); }}>Load results</Button>
    </div>
    {(error || result.error) && <p role="alert" className="text-destructive">{error || result.error?.message}</p>}
    {fleet && <section className="space-y-4">
      <p>Run ID: <code>{fleet.id}</code> · {fleet.complete ? "Complete" : fleet.confirmed ? "Running" : "Awaiting confirmation"}</p>
      <pre className="whitespace-pre-wrap rounded border p-3">{JSON.stringify(fleet.command)}</pre>
      {!fleet.confirmed && <p>Preview expires at {new Date(fleet.deadline).toLocaleString()}. VMs without command permission are skipped; eligibility and permissions are checked again at confirmation.</p>}
      {fleet.entries.map((entry) => {
        const operation = (entry.operationID && fullOutput[entry.operationID]) || fleet.operations.find((item) => item.id === entry.operationID);
        return <article key={entry.vmID} className="rounded border p-4 space-y-2">
          <p className="font-medium">{entry.name ?? "Missing or inaccessible VM"} · {entry.vmID}</p>
          <p>{operation?.status ?? entry.state}{operation?.result?.exitCode !== undefined ? ` · Exit ${operation.result.exitCode}` : ""}</p>
          {(entry.reason || operation?.error) && <p>{entry.reason || operation?.error}</p>}
          {operation?.result && <>
            <p>stdout</p><pre className="max-h-64 overflow-auto whitespace-pre-wrap">{operation.result.stdout}</pre>
            <p>stderr</p><pre className="max-h-64 overflow-auto whitespace-pre-wrap">{operation.result.stderr}</pre>
            {operation.result.truncated && <p>Output truncated{entry.operationID && !fullOutput[entry.operationID] && <Button variant="outline" onClick={async () => {
              try {
                const full = await apiClient<Operation>(`/api/operations/${entry.operationID}`);
                setFullOutput((previous) => ({ ...previous, [entry.operationID!]: full }));
              } catch (cause) { setError(cause instanceof Error ? cause.message : "Could not load output."); }
            }}>Load full captured output</Button>}</p>}
          </>}
          {entry.operationID && <p className="text-sm">Operation: {entry.operationID}</p>}
        </article>;
      })}
      {!fleet.confirmed && <Button onClick={confirm} disabled={busy || !fleet.entries.some((entry) => entry.state === "ready")}>Confirm and run on these VMs</Button>}
    </section>}
  </div>;
}
