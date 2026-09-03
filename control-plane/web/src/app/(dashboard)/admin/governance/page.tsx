"use client";

import { formatDateTime } from "@/lib/format-time";

import { confirmAction } from "@/providers/confirmation-provider";

import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import {
  Activity,
  ShieldAlert,
  Trash2,
  Wrench,
} from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { QueryErrorNotice } from "@/components/ui/query-error-notice";
import { platformOperationsApi } from "@/lib/api/platform-services";
import { useWorkMutation } from "@/lib/hooks";
import { useAuth, useProjectContext } from "@/providers";

export default function GovernancePage() {
  const { user } = useAuth();
  const { currentProject } = useProjectContext();
  const queryClient = useQueryClient();
  const [guardrailName, setGuardrailName] = useState("");
  const [guardrailActions, setGuardrailActions] = useState("");
  const [whoAction, setWhoAction] = useState("vm:read");
  const [whoNodeType, setWhoNodeType] = useState("project");
  const [whoNodeId, setWhoNodeId] = useState("");

  const versionQuery = useQuery({
    queryKey: ["iam-policy-version"],
    queryFn: ({ signal }) => platformOperationsApi.policySetVersion(signal),
    enabled: !!user?.isSystemAdmin,
  });
  const summaryQuery = useQuery({
    queryKey: ["iam-decision-summary", 24],
    queryFn: ({ signal }) => platformOperationsApi.decisionSummary(24, signal),
    enabled: !!user?.isSystemAdmin,
    refetchInterval: 30_000,
  });
  const logsQuery = useQuery({
    queryKey: ["iam-decision-logs"],
    queryFn: ({ signal }) => platformOperationsApi.listDecisionLogs(100, signal),
    enabled: !!user?.isSystemAdmin,
  });
  const hierarchyQuery = useQuery({
    queryKey: ["hierarchy-validation"],
    queryFn: ({ signal }) => platformOperationsApi.validateHierarchy(signal),
    enabled: !!user?.isSystemAdmin,
  });
  const guardrailsQuery = useQuery({
    queryKey: ["iam-guardrails", { projectId: currentProject?.id }],
    queryFn: ({ signal }) => platformOperationsApi.listGuardrails("project", currentProject!.id, signal),
    enabled: !!currentProject,
  });

  const refresh = () => {
    for (const key of ["iam-policy-version", "iam-decision-summary", "iam-decision-logs", "hierarchy-validation", "iam-guardrails"]) {
      void queryClient.invalidateQueries({ queryKey: [key] });
    }
  };
  const mutation = useWorkMutation({
    onSuccess: refresh,
    successMessage: "Governance configuration updated",
  });
  const whoCan = useMutation({
    mutationFn: () =>
      platformOperationsApi.whoCan({
        action: whoAction,
        node: { type: whoNodeType as "project", id: whoNodeId },
      }),
    onError: (error) => toast.error(error.message),
  });

  if (!user?.isSystemAdmin) {
    return <p className="py-12 text-center text-muted-foreground">System administrator access is required.</p>;
  }

  const error = versionQuery.error ?? summaryQuery.error ?? logsQuery.error ?? hierarchyQuery.error;
  const report = hierarchyQuery.data;

  return (
    <div className="mx-auto max-w-7xl space-y-6">
      <div><h1 className="text-2xl font-semibold">Governance operations</h1><p className="text-muted-foreground">Policy health, authorization decisions, guardrails, and hierarchy integrity</p></div>
      <QueryErrorNotice resource="governance telemetry" error={error} hasData={versionQuery.data !== undefined || summaryQuery.data !== undefined} onRetry={refresh} />

      <div className="grid gap-4 md:grid-cols-3">
        <Card><CardHeader><CardTitle className="text-sm">Policy version</CardTitle></CardHeader><CardContent><p className="text-2xl font-semibold">{versionQuery.data?.version ?? "—"}</p><p className="text-sm text-muted-foreground">Replica {versionQuery.data?.replicaVersion ?? "—"}</p></CardContent></Card>
        <Card><CardHeader><CardTitle className="text-sm">Hierarchy issues</CardTitle></CardHeader><CardContent><p className="text-2xl font-semibold">{report?.summary.totalIssues ?? "—"}</p><p className="text-sm text-muted-foreground">{report?.summary.criticalIssues ?? 0} critical</p></CardContent></Card>
        <Card><CardHeader><CardTitle className="text-sm">Decisions in top buckets</CardTitle></CardHeader><CardContent><p className="text-2xl font-semibold">{(summaryQuery.data ?? []).reduce((sum, bucket) => sum + bucket.count, 0)}</p><p className="text-sm text-muted-foreground">Last 24 hours</p></CardContent></Card>
      </div>

      <Card><CardHeader><CardTitle className="flex items-center gap-2"><Wrench className="h-5 w-5" />Hierarchy integrity</CardTitle></CardHeader><CardContent className="space-y-3">{report?.issues.map((issue) => <div key={issue.id} className="rounded-lg border p-3"><p className="font-medium">{issue.entityName} · {issue.type}</p><p className="text-sm text-muted-foreground">{issue.description}</p></div>)}{report?.issues.length === 0 && <p className="text-sm text-muted-foreground">Hierarchy paths and parents are consistent.</p>}<Button variant="outline" disabled={!report?.issues.some((issue) => issue.type === "broken_path") || mutation.isPending} onClick={async () => await confirmAction("Rebuild every drifted hierarchy path now?") && mutation.mutate(() => platformOperationsApi.repairHierarchy({ repairAll: true, repairOptions: { rebuildPaths: true } }))}>Rebuild drifted paths</Button></CardContent></Card>

      {currentProject && <Card><CardHeader><CardTitle className="flex items-center gap-2"><ShieldAlert className="h-5 w-5" />Effective project guardrails</CardTitle></CardHeader><CardContent className="space-y-4"><form className="grid gap-3 md:grid-cols-[1fr_2fr_auto]" onSubmit={(event) => { event.preventDefault(); mutation.mutate(() => platformOperationsApi.createGuardrail({ name: guardrailName, nodeType: "project", nodeId: currentProject.id, actions: guardrailActions.split(",").map((value) => value.trim()).filter(Boolean), enabled: true })); }}><div><Label htmlFor="guardrail-name">Name</Label><Input id="guardrail-name" value={guardrailName} onChange={(e) => setGuardrailName(e.target.value)} required /></div><div><Label htmlFor="guardrail-actions">Forbidden actions</Label><Input id="guardrail-actions" value={guardrailActions} onChange={(e) => setGuardrailActions(e.target.value)} placeholder="vm:delete, volume:delete" /></div><Button className="self-end">Create guardrail</Button></form><div className="divide-y rounded-lg border">{(guardrailsQuery.data?.guardrails ?? []).map((guardrail) => <div key={guardrail.id} className="flex items-center justify-between p-3"><div><p className="font-medium">{guardrail.name}</p><p className="text-sm text-muted-foreground">{guardrail.enabled ? "Enabled" : "Disabled"} · {guardrail.actions.join(", ") || "All actions"} · {guardrail.shape}</p></div><Button variant="ghost" size="icon" aria-label={`Delete ${guardrail.name}`} onClick={async () => await confirmAction(`Delete guardrail ${guardrail.name}?`) && mutation.mutate(() => platformOperationsApi.deleteGuardrail(guardrail.id))}><Trash2 className="h-4 w-4" /></Button></div>)}</div></CardContent></Card>}

      <Card><CardHeader><CardTitle>Who can?</CardTitle></CardHeader><CardContent className="space-y-4"><form className="grid gap-3 md:grid-cols-[1fr_1fr_2fr_auto]" onSubmit={(event) => { event.preventDefault(); whoCan.mutate(); }}><div><Label htmlFor="who-action">Action</Label><Input id="who-action" value={whoAction} onChange={(e) => setWhoAction(e.target.value)} required /></div><div><Label htmlFor="who-node-type">Node type</Label><Input id="who-node-type" value={whoNodeType} onChange={(e) => setWhoNodeType(e.target.value)} required /></div><div><Label htmlFor="who-node-id">Node ID</Label><Input id="who-node-id" value={whoNodeId} onChange={(e) => setWhoNodeId(e.target.value)} placeholder={currentProject?.id} required /></div><Button className="self-end">Resolve</Button></form>{whoCan.data && <pre className="max-h-80 overflow-auto rounded-lg bg-muted p-3 text-xs">{JSON.stringify(whoCan.data, null, 2)}</pre>}</CardContent></Card>

      <Card><CardHeader><CardTitle className="flex items-center gap-2"><Activity className="h-5 w-5" />Recent authorization decisions</CardTitle></CardHeader><CardContent><div className="overflow-x-auto"><table className="w-full text-left text-sm"><thead><tr className="border-b"><th className="p-2">Time</th><th className="p-2">Decision</th><th className="p-2">Action</th><th className="p-2">Subject</th><th className="p-2">Tier</th></tr></thead><tbody>{(logsQuery.data ?? []).map((entry) => <tr key={entry.id} className="border-b"><td className="p-2 whitespace-nowrap">{entry.createdAt ? formatDateTime(entry.createdAt) : "—"}</td><td className="p-2">{entry.decision}</td><td className="p-2 font-mono">{entry.action ?? "—"}</td><td className="p-2 font-mono">{entry.subject}</td><td className="p-2">{entry.tier ?? "—"}</td></tr>)}</tbody></table></div></CardContent></Card>
    </div>
  );
}
