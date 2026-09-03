"use client";

import { confirmAction } from "@/providers/confirmation-provider";

import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { KeyRound, Trash2, UserCog } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { QueryErrorNotice } from "@/components/ui/query-error-notice";
import { ProjectRequiredState } from "@/components/ui/project-required-state";
import { usePermissions, useWorkMutation } from "@/lib/hooks";
import {
  registryCredentialsApi,
  serviceAccountsApi,
} from "@/lib/api/platform-services";
import { selectedServiceAccountForProject } from "@/lib/service-account-selection";
import { useProjectContext } from "@/providers";

export default function ProjectIntegrationsPage() {
  const { currentProject } = useProjectContext();
  const projectId = currentProject?.id;
  const queryClient = useQueryClient();
  const [registry, setRegistry] = useState("");
  const [username, setUsername] = useState("");
  const [secret, setSecret] = useState("");
  const [accountName, setAccountName] = useState("");
  const [accountDescription, setAccountDescription] = useState("");
  const [selectedAccount, setSelectedAccount] = useState("");
  const [spiffeId, setSpiffeId] = useState("");
  const [accountRole, setAccountRole] = useState<"viewer" | "operator" | "editor" | "admin">("viewer");

  const permissions = usePermissions(
    projectId
      ? [
          {
            key: "manage_credentials",
            action: "iam:setPolicy",
            node: { type: "project", id: projectId },
          },
          {
            key: "create_service_account",
            action: "serviceaccount:create",
            node: { type: "project", id: projectId },
          },
        ]
      : []
  ).permissions;

  const credentialsQuery = useQuery({
    queryKey: ["registry-credentials", { projectId }],
    queryFn: ({ signal }) => registryCredentialsApi.list(projectId!, signal),
    enabled: !!projectId,
  });
  const accountsQuery = useQuery({
    queryKey: ["service-accounts", { projectId }],
    queryFn: ({ signal }) => serviceAccountsApi.list(projectId!, signal),
    enabled: !!projectId,
  });
  const selectedAccountForProject = selectedServiceAccountForProject(
    accountsQuery.data,
    selectedAccount,
    projectId
  );
  const selectedAccountId = selectedAccountForProject?.id ?? "";
  const registrationsQuery = useQuery({
    queryKey: ["service-account-registrations", selectedAccountId],
    queryFn: ({ signal }) =>
      serviceAccountsApi.listRegistrations(selectedAccountId, signal),
    enabled: !!selectedAccountId,
  });
  const accountPermissions = usePermissions(
    (accountsQuery.data ?? []).map((account) => ({
      key: `delete:${account.id}`,
      action: "serviceaccount:delete",
      node: { type: "service_account" as const, id: account.id },
    }))
  ).permissions;

  const refresh = () => {
    void queryClient.invalidateQueries({ queryKey: ["registry-credentials"] });
    void queryClient.invalidateQueries({ queryKey: ["service-accounts"] });
    void queryClient.invalidateQueries({ queryKey: ["service-account-registrations"] });
  };

  const createCredential = useMutation({
    mutationFn: () =>
      registryCredentialsApi.create(projectId!, { registry, username, secret }),
    onSuccess: () => {
      setRegistry("");
      setUsername("");
      setSecret("");
      refresh();
      toast.success("Registry credential added");
    },
    onError: (error) => toast.error(error.message),
  });
  const deleteCredential = useMutation({
    mutationFn: (id: string) => registryCredentialsApi.delete(projectId!, id),
    onSuccess: refresh,
    onError: (error) => toast.error(error.message),
  });
  const createAccount = useMutation({
    mutationFn: () =>
      serviceAccountsApi.create(projectId!, {
        name: accountName,
        description: accountDescription || undefined,
      }),
    onSuccess: () => {
      setAccountName("");
      setAccountDescription("");
      refresh();
      toast.success("Service account created");
    },
    onError: (error) => toast.error(error.message),
  });
  const deleteAccount = useMutation({
    mutationFn: serviceAccountsApi.delete,
    onSuccess: refresh,
    onError: (error) => toast.error(error.message),
  });
  const manageAccount = useWorkMutation({
    onSuccess: refresh,
    successMessage: "Service account updated",
  });

  if (!currentProject) {
    return <ProjectRequiredState resource="Project integrations" />;
  }

  return (
    <div className="mx-auto max-w-5xl space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Project integrations</h1>
        <p className="text-muted-foreground">
          Machine identities and private registry access for {currentProject.name}
        </p>
      </div>

      <QueryErrorNotice
        resource="project integrations"
        error={credentialsQuery.error ?? accountsQuery.error}
        hasData={credentialsQuery.data !== undefined || accountsQuery.data !== undefined}
        onRetry={() => {
          void credentialsQuery.refetch();
          void accountsQuery.refetch();
        }}
      />

      <Card>
        <CardHeader><CardTitle className="flex items-center gap-2"><KeyRound className="h-5 w-5" />Registry credentials</CardTitle></CardHeader>
        <CardContent className="space-y-5">
          {permissions.manage_credentials && (
            <form
              className="grid gap-3 md:grid-cols-4"
              onSubmit={(event) => {
                event.preventDefault();
                createCredential.mutate();
              }}
            >
              <div><Label htmlFor="registry-host">Registry</Label><Input id="registry-host" value={registry} onChange={(e) => setRegistry(e.target.value)} placeholder="ghcr.io" required /></div>
              <div><Label htmlFor="registry-user">Username</Label><Input id="registry-user" value={username} onChange={(e) => setUsername(e.target.value)} required /></div>
              <div><Label htmlFor="registry-secret">Secret</Label><Input id="registry-secret" type="password" value={secret} onChange={(e) => setSecret(e.target.value)} required /></div>
              <Button className="self-end" disabled={createCredential.isPending}>Add credential</Button>
            </form>
          )}
          <div className="divide-y divide-border rounded-lg border">
            {(credentialsQuery.data ?? []).map((credential) => (
              <div key={credential.id} className="flex items-center justify-between gap-4 p-3">
                <div><p className="font-medium">{credential.registry}</p><p className="text-sm text-muted-foreground">{credential.username}</p></div>
                {permissions.manage_credentials && credential.id && <Button variant="ghost" size="icon" aria-label={`Delete credential for ${credential.registry}`} onClick={async () => await confirmAction(`Delete the credential for ${credential.registry}?`) && deleteCredential.mutate(credential.id!)}><Trash2 className="h-4 w-4" /></Button>}
              </div>
            ))}
            {credentialsQuery.data?.length === 0 && <p className="p-4 text-sm text-muted-foreground">No private registry credentials.</p>}
          </div>
        </CardContent>
      </Card>

      <Card>
        <CardHeader><CardTitle className="flex items-center gap-2"><UserCog className="h-5 w-5" />Service accounts</CardTitle></CardHeader>
        <CardContent className="space-y-5">
          {permissions.create_service_account && (
            <form className="grid gap-3 md:grid-cols-[1fr_2fr_auto]" onSubmit={(event) => { event.preventDefault(); createAccount.mutate(); }}>
              <div><Label htmlFor="account-name">Name</Label><Input id="account-name" value={accountName} onChange={(e) => setAccountName(e.target.value)} required /></div>
              <div><Label htmlFor="account-description">Description</Label><Input id="account-description" value={accountDescription} onChange={(e) => setAccountDescription(e.target.value)} /></div>
              <Button className="self-end" disabled={createAccount.isPending}>Create account</Button>
            </form>
          )}
          <div className="divide-y divide-border rounded-lg border">
            {(accountsQuery.data ?? []).map((account) => (
              <div key={account.id} className="flex flex-col gap-3 p-3 sm:flex-row sm:items-center sm:justify-between">
                <div><p className="font-medium">{account.name}</p><p className="text-sm text-muted-foreground">{account.description || "No description"} · {account.projectRoles.join(", ") || "No project role"}</p></div>
                <div className="flex gap-2"><Button variant="outline" size="sm" onClick={() => setSelectedAccount(selectedAccountId === account.id ? "" : account.id)}>{selectedAccountId === account.id ? "Close" : "Manage identity"}</Button>{accountPermissions[`delete:${account.id}`] && <Button variant="ghost" size="icon" aria-label={`Delete ${account.name}`} onClick={async () => await confirmAction(`Delete service account ${account.name} and all its identity registrations?`) && deleteAccount.mutate(account.id)}><Trash2 className="h-4 w-4" /></Button>}</div>
              </div>
            ))}
            {accountsQuery.data?.length === 0 && <p className="p-4 text-sm text-muted-foreground">No service accounts.</p>}
          </div>
          {selectedAccountId && permissions.manage_credentials && (
            <div className="space-y-4 rounded-lg border p-4">
              <h3 className="font-medium">Role and SPIFFE identities</h3>
              <div className="flex flex-col gap-2 sm:flex-row">
                <Label className="sr-only" htmlFor="service-account-role">Project role</Label>
                <select id="service-account-role" value={accountRole} onChange={(event) => setAccountRole(event.target.value as typeof accountRole)} className="h-9 rounded-md border border-input bg-background px-3 text-sm">{["viewer", "operator", "editor", "admin"].map((role) => <option key={role}>{role}</option>)}</select>
                <Button variant="outline" onClick={() => manageAccount.mutate(() => serviceAccountsApi.setProjectRole(selectedAccountId, accountRole))}>Set role</Button>
                <Button variant="ghost" onClick={() => manageAccount.mutate(() => serviceAccountsApi.clearProjectRole(selectedAccountId))}>Clear role</Button>
              </div>
              <form className="flex flex-col gap-2 sm:flex-row" onSubmit={(event) => { event.preventDefault(); manageAccount.mutate(() => serviceAccountsApi.createRegistration(selectedAccountId, spiffeId)); }}>
                <div className="flex-1"><Label htmlFor="service-account-spiffe">SPIFFE ID</Label><Input id="service-account-spiffe" value={spiffeId} onChange={(event) => setSpiffeId(event.target.value)} placeholder="spiffe://example.org/workload/api" required /></div>
                <Button className="self-end">Register</Button>
              </form>
              <div className="divide-y">{(registrationsQuery.data ?? []).map((registration) => <div key={registration.id} className="flex items-center justify-between py-2"><code className="overflow-x-auto text-sm">{registration.spiffeId}</code><Button variant="ghost" size="icon" aria-label={`Remove ${registration.spiffeId}`} onClick={async () => await confirmAction(`Remove identity ${registration.spiffeId}?`) && manageAccount.mutate(() => serviceAccountsApi.deleteRegistration(selectedAccountId, registration.id))}><Trash2 className="h-4 w-4" /></Button></div>)}</div>
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
