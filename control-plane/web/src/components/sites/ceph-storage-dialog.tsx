"use client";

import {
  useMemo,
  useState,
  type FormEvent,
  type SetStateAction,
} from "react";
import { Database, Loader2, ShieldCheck, Trash2 } from "lucide-react";
import { toast } from "sonner";
import { errorMessage } from "@/lib/errors";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  useCephCluster,
  useCephProjectAccess,
  useConfigureCephProjectAccess,
  useDeleteCephCluster,
  useDeleteCephProjectAccess,
  useHierarchy,
  usePermissions,
  useProjectsForOrganization,
  useRegisterCephCluster,
  useUpdateCephCluster,
} from "@/lib/hooks";
import { useOrganization } from "@/providers";
import type { FolderNode, Site } from "@/types/api";

const selectClassName =
  "h-9 w-full rounded-md border border-input bg-background px-3 py-2 text-sm text-foreground focus:outline-none focus:ring-2 focus:ring-ring disabled:cursor-not-allowed disabled:opacity-50";
const textareaClassName =
  "min-h-20 w-full rounded-md border border-input bg-background px-3 py-2 font-mono text-xs text-foreground shadow-sm outline-none placeholder:text-muted-foreground focus:ring-2 focus:ring-ring disabled:cursor-not-allowed disabled:opacity-50";

interface CephStorageDialogProps {
  site: Site | null;
  open: boolean;
  onOpenChange: (open: boolean) => void;
}

interface ClusterForm {
  fsid: string;
  monEndpoints: string;
  clientName: string;
  keyring: string;
}

interface ProjectAccessForm {
  clientName: string;
  keyring: string;
  storagePoolName: string;
  cephPoolName: string;
  namespace: string;
}

const EMPTY_CLUSTER_FORM: ClusterForm = {
  fsid: "",
  monEndpoints: "",
  clientName: "client.strato-observer",
  keyring: "",
};

const EMPTY_ACCESS_FORM: ProjectAccessForm = {
  clientName: "",
  keyring: "",
  storagePoolName: "",
  cephPoolName: "rbd",
  namespace: "",
};

function endpointList(raw: string): string[] {
  return Array.from(
    new Set(
      raw
        .split(/[\n,]+/)
        .map((value) => value.trim())
        .filter(Boolean)
    )
  );
}

function safeName(value: string): string {
  return value
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9_.-]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

function projectIdsInFolder(
  folders: FolderNode[],
  folderId: string
): Set<string> | null {
  for (const folder of folders) {
    if (folder.id === folderId) {
      const ids = new Set(folder.projects.map((project) => project.id));
      const collect = (children: FolderNode[]) => {
        for (const child of children) {
          child.projects.forEach((project) => ids.add(project.id));
          collect(child.childOUs);
        }
      };
      collect(folder.childOUs);
      return ids;
    }
    const nested = projectIdsInFolder(folder.childOUs, folderId);
    if (nested) return nested;
  }
  return null;
}

export function CephStorageDialog({
  site,
  open,
  onOpenChange,
}: CephStorageDialogProps) {
  // A site change remounts the stateful editor, ensuring a draft keyring from
  // one site can never survive into another site's dialog.
  return (
    <CephStorageDialogEditor
      key={site?.id ?? "no-site"}
      site={site}
      open={open}
      onOpenChange={onOpenChange}
    />
  );
}

function CephStorageDialogEditor({
  site,
  open,
  onOpenChange,
}: CephStorageDialogProps) {
  const siteId = site?.id;
  const { currentOrg } = useOrganization();
  const projectsQuery = useProjectsForOrganization(currentOrg?.id);
  const hierarchyQuery = useHierarchy(
    open && site?.organizationalUnitId ? currentOrg?.id : undefined
  );
  const containedProjects = useMemo(() => {
    const allProjects = projectsQuery.data ?? [];
    if (!site) return [];
    if (site.organizationId) {
      return site.organizationId === currentOrg?.id ? allProjects : [];
    }
    if (!site.organizationalUnitId || !hierarchyQuery.data) return [];
    const ids = projectIdsInFolder(
      hierarchyQuery.data.organization.organizationalUnits,
      site.organizationalUnitId
    );
    return ids ? allProjects.filter((project) => ids.has(project.id)) : [];
  }, [currentOrg?.id, hierarchyQuery.data, projectsQuery.data, site]);
  const {
    permissions: projectPermissions,
    isLoading: projectPermissionsLoading,
    error: projectPermissionsError,
  } = usePermissions(
    open
      ? containedProjects.map((project) => ({
          key: `manage-project:${project.id}`,
          action: "iam:setPolicy",
          node: { type: "project" as const, id: project.id },
        }))
      : []
  );
  const projects = useMemo(
    () =>
      containedProjects.filter(
        (project) => projectPermissions[`manage-project:${project.id}`]
      ),
    [containedProjects, projectPermissions]
  );
  const projectsLoading =
    projectsQuery.isLoading ||
    (!!site?.organizationalUnitId && hierarchyQuery.isLoading) ||
    projectPermissionsLoading;
  const clusterQuery = useCephCluster(siteId, open);
  const cluster = clusterQuery.data ?? null;
  const clusterFormKey = cluster
    ? `${cluster.id ?? cluster.siteId}:${cluster.updatedAt ?? "registered"}`
    : `new:${siteId ?? "none"}`;
  const defaultClusterForm: ClusterForm = cluster
    ? {
        fsid: cluster.fsid,
        monEndpoints: cluster.monEndpoints.join("\n"),
        clientName: cluster.clientName,
        keyring: "",
      }
    : EMPTY_CLUSTER_FORM;
  const [clusterDraft, setClusterDraft] = useState<{
    key: string;
    form: ClusterForm;
  } | null>(null);
  const clusterForm =
    clusterDraft?.key === clusterFormKey
      ? clusterDraft.form
      : defaultClusterForm;
  const setClusterForm = (update: SetStateAction<ClusterForm>) => {
    const form =
      typeof update === "function" ? update(clusterForm) : update;
    setClusterDraft({ key: clusterFormKey, form });
  };

  const [requestedProjectId, setRequestedProjectId] = useState("");
  const selectedProjectId = projects.some(
    (project) => project.id === requestedProjectId
  )
    ? requestedProjectId
    : (projects[0]?.id ?? "");
  const registerCluster = useRegisterCephCluster(siteId ?? "");
  const updateCluster = useUpdateCephCluster(siteId ?? "");
  const deleteCluster = useDeleteCephCluster(siteId ?? "");
  const accessQuery = useCephProjectAccess(
    siteId,
    selectedProjectId || undefined,
    open && !!cluster
  );
  const access = accessQuery.data ?? null;
  const configureAccess = useConfigureCephProjectAccess(
    siteId ?? "",
    selectedProjectId
  );
  const deleteAccess = useDeleteCephProjectAccess(
    siteId ?? "",
    selectedProjectId
  );
  const project = projects.find((item) => item.id === selectedProjectId);
  const projectSlug = safeName(project?.name ?? selectedProjectId);
  const siteSlug = safeName(site?.name ?? "site");
  const projectIdentity = selectedProjectId.toLowerCase();
  const accessFormKey = access
    ? `${access.id ?? access.projectId}:${access.updatedAt ?? "configured"}`
    : `new:${siteId ?? "none"}:${selectedProjectId}`;
  const defaultAccessForm: ProjectAccessForm = access
    ? {
        clientName: access.clientName,
        keyring: "",
        storagePoolName: access.storagePool.name,
        cephPoolName: access.storagePool.cephPoolName ?? "rbd",
        namespace: access.storagePool.cephNamespace ?? "",
      }
    : selectedProjectId
      ? {
          clientName: `client.strato-${projectIdentity}`,
          keyring: "",
          storagePoolName: `${siteSlug.slice(0, 32)}-${projectSlug.slice(0, 40)}-${projectIdentity.slice(0, 8)}-ceph`,
          cephPoolName: "rbd",
          namespace: projectIdentity,
        }
      : EMPTY_ACCESS_FORM;
  const [accessDraft, setAccessDraft] = useState<{
    key: string;
    form: ProjectAccessForm;
  } | null>(null);
  const accessForm =
    accessDraft?.key === accessFormKey ? accessDraft.form : defaultAccessForm;
  const setAccessForm = (update: SetStateAction<ProjectAccessForm>) => {
    const form = typeof update === "function" ? update(accessForm) : update;
    setAccessDraft({ key: accessFormKey, form });
  };
  const setSelectedProjectId = (projectId: string) => {
    // Project credentials are write-only. Drop both the draft and React
    // Query's last mutation variables before switching identities.
    setAccessDraft(null);
    configureAccess.reset();
    deleteAccess.reset();
    setRequestedProjectId(projectId);
  };

  const clusterPending =
    registerCluster.isPending || updateCluster.isPending || deleteCluster.isPending;
  const accessPending = configureAccess.isPending || deleteAccess.isPending;

  const handleClusterSubmit = (event: FormEvent) => {
    event.preventDefault();
    if (!siteId) return;
    const monitors = endpointList(clusterForm.monEndpoints);
    if (monitors.length === 0) {
      toast.error("Enter at least one Ceph monitor endpoint");
      return;
    }
    if (!clusterForm.clientName.trim().startsWith("client.")) {
      toast.error("The Ceph client name must begin with client.");
      return;
    }
    if (!cluster && !clusterForm.keyring.trim()) {
      toast.error("Enter the observer keyring for this cluster");
      return;
    }

    const onSuccess = () => {
      toast.success(cluster ? "Ceph cluster updated" : "Ceph cluster registered");
    };
    const onError = (error: unknown) =>
      toast.error(errorMessage(error, "Failed to save Ceph cluster"));

    if (cluster) {
      updateCluster.mutate(
        {
          monEndpoints: monitors,
          clientName: clusterForm.clientName.trim(),
          keyring: clusterForm.keyring.trim() || undefined,
        },
        {
          onSuccess,
          onError,
          onSettled: () => {
            setClusterForm((current) => ({ ...current, keyring: "" }));
            updateCluster.reset();
          },
        }
      );
    } else {
      registerCluster.mutate(
        {
          fsid: clusterForm.fsid.trim(),
          monEndpoints: monitors,
          clientName: clusterForm.clientName.trim(),
          keyring: clusterForm.keyring.trim(),
        },
        {
          onSuccess,
          onError,
          onSettled: () => {
            setClusterForm((current) => ({ ...current, keyring: "" }));
            registerCluster.reset();
          },
        }
      );
    }
  };

  const handleAccessSubmit = (event: FormEvent) => {
    event.preventDefault();
    if (!siteId || !selectedProjectId) return;
    if (!accessForm.clientName.trim().startsWith("client.")) {
      toast.error("The project Ceph client name must begin with client.");
      return;
    }
    if (!access && !accessForm.keyring.trim()) {
      toast.error("Enter the project-scoped keyring");
      return;
    }
    if (
      !accessForm.storagePoolName.trim() ||
      !accessForm.cephPoolName.trim() ||
      !accessForm.namespace.trim()
    ) {
      toast.error("Pool name, Ceph pool, and namespace are required");
      return;
    }

    const replacesCredential = !!access && !!accessForm.keyring.trim();
    if (
      replacesCredential &&
      !window.confirm(
        "Confirm that the old cephx key is no longer accepted by the external Ceph cluster. Strato does not revoke or rotate external Ceph credentials."
      )
    ) {
      return;
    }

    configureAccess.mutate(
      {
        clientName: accessForm.clientName.trim(),
        keyring: accessForm.keyring.trim() || undefined,
        storagePoolName: accessForm.storagePoolName.trim(),
        cephPoolName: accessForm.cephPoolName.trim(),
        namespace: accessForm.namespace.trim(),
        cephxRevoked: replacesCredential ? true : undefined,
      },
      {
        onSuccess: () => {
          toast.success(access ? "Project Ceph access updated" : "Project Ceph access configured");
        },
        onError: (error) =>
          toast.error(errorMessage(error, "Failed to configure project access")),
        onSettled: () => {
          setAccessForm((current) => ({ ...current, keyring: "" }));
          configureAccess.reset();
        },
      }
    );
  };

  const handleOpenChange = (nextOpen: boolean) => {
    if (!nextOpen) {
      // Clear every copy of submitted or unsubmitted key material. Mutation
      // reset matters because TanStack retains the last variables by default.
      setClusterDraft(null);
      setAccessDraft(null);
      registerCluster.reset();
      updateCluster.reset();
      configureAccess.reset();
    }
    onOpenChange(nextOpen);
  };

  const handleDeleteCluster = () => {
    if (!site || !window.confirm(`Remove the external Ceph cluster from ${site.name}? Existing pools or volumes must be removed first.`)) {
      return;
    }
    deleteCluster.mutate(undefined, {
      onSuccess: () => toast.success("Ceph cluster removed"),
      onError: (error) =>
        toast.error(errorMessage(error, "Failed to remove Ceph cluster")),
    });
  };

  const handleDeleteAccess = () => {
    const project = projects.find((item) => item.id === selectedProjectId);
    if (!window.confirm(`Remove Ceph access for ${project?.name ?? "this project"}? Its pool must contain no volumes, and you must already have revoked this cephx identity in the external Ceph cluster. Strato will remove only its stored configuration.`)) {
      return;
    }
    deleteAccess.mutate(true, {
      onSuccess: () => toast.success("Project Ceph access removed"),
      onError: (error) =>
        toast.error(errorMessage(error, "Failed to remove project access")),
    });
  };

  return (
    <Dialog open={open} onOpenChange={handleOpenChange}>
      <DialogContent className="max-h-[92vh] overflow-y-auto bg-card sm:max-w-[760px]">
        <DialogHeader>
          <DialogTitle>Ceph storage · {site?.name}</DialogTitle>
          <DialogDescription>
            Register an existing cluster, then give each project its own RBD
            namespace and scoped cephx identity. Agents remain clients only.
          </DialogDescription>
        </DialogHeader>

        {clusterQuery.isLoading ? (
          <div className="flex items-center justify-center gap-2 py-14 text-sm text-muted-foreground">
            <Loader2 className="h-4 w-4 animate-spin" />
            Loading Ceph configuration…
          </div>
        ) : clusterQuery.error ? (
          <div className="rounded-md border border-destructive/30 bg-destructive/5 p-3 text-sm text-destructive">
            {errorMessage(clusterQuery.error, "Failed to load Ceph configuration")}
          </div>
        ) : (
          <div className="space-y-5 py-2">
            <form
              onSubmit={handleClusterSubmit}
              className="space-y-4 rounded-lg border border-border p-4"
            >
              <div className="flex items-start gap-3">
                <Database className="mt-0.5 h-4 w-4 text-muted-foreground" />
                <div className="flex-1">
                  <div className="text-sm font-semibold">External cluster</div>
                  <div className="mt-0.5 text-xs text-muted-foreground">
                    {cluster
                      ? `Registered · health ${cluster.health}`
                      : "No Ceph cluster is registered for this site."}
                  </div>
                </div>
                {cluster && (
                  <span className="rounded-full bg-muted px-2 py-1 font-mono text-[10px] uppercase text-muted-foreground">
                    unmanaged
                  </span>
                )}
              </div>

              <div className="grid gap-4 sm:grid-cols-2">
                <div className="space-y-2">
                  <Label htmlFor="ceph-fsid">Cluster FSID</Label>
                  <Input
                    id="ceph-fsid"
                    value={clusterForm.fsid}
                    placeholder="00000000-0000-0000-0000-000000000000"
                    onChange={(event) =>
                      setClusterForm((current) => ({
                        ...current,
                        fsid: event.target.value,
                      }))
                    }
                    disabled={clusterPending || !!cluster}
                    required
                  />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="ceph-observer-client">Observer client</Label>
                  <Input
                    id="ceph-observer-client"
                    value={clusterForm.clientName}
                    placeholder="client.strato-observer"
                    onChange={(event) =>
                      setClusterForm((current) => ({
                        ...current,
                        clientName: event.target.value,
                      }))
                    }
                    disabled={clusterPending}
                    required
                  />
                </div>
              </div>

              <div className="space-y-2">
                <Label htmlFor="ceph-monitors">Monitor endpoints</Label>
                <textarea
                  id="ceph-monitors"
                  className={textareaClassName}
                  value={clusterForm.monEndpoints}
                  placeholder={"v2:10.0.0.10:3300\nv2:[2001:db8::10]:3300"}
                  onChange={(event) =>
                    setClusterForm((current) => ({
                      ...current,
                      monEndpoints: event.target.value,
                    }))
                  }
                  disabled={clusterPending}
                  spellCheck={false}
                  required
                />
                <p className="text-xs text-muted-foreground">
                  One explicit v2 endpoint per line. Agents force secure messenger mode.
                </p>
              </div>

              <div className="space-y-2">
                <Label htmlFor="ceph-observer-keyring">
                  Observer keyring {cluster && "(leave blank to keep current)"}
                </Label>
                <textarea
                  id="ceph-observer-keyring"
                  className={textareaClassName}
                  value={clusterForm.keyring}
                  placeholder="[client.strato-observer]"
                  onChange={(event) =>
                    setClusterForm((current) => ({
                      ...current,
                      keyring: event.target.value,
                    }))
                  }
                  disabled={clusterPending}
                  autoComplete="off"
                  spellCheck={false}
                />
                <p className="flex items-center gap-1.5 text-xs text-muted-foreground">
                  <ShieldCheck className="h-3.5 w-3.5" />
                  Encrypted at rest and write-only; it is never returned by the API.
                </p>
              </div>

              <div className="flex justify-between gap-3">
                <div>
                  {cluster && (
                    <Button
                      type="button"
                      variant="ghost"
                      className="text-destructive hover:text-destructive"
                      onClick={handleDeleteCluster}
                      disabled={clusterPending}
                    >
                      <Trash2 className="h-4 w-4" />
                      Remove cluster
                    </Button>
                  )}
                </div>
                <Button type="submit" disabled={clusterPending}>
                  {clusterPending && <Loader2 className="h-4 w-4 animate-spin" />}
                  {cluster ? "Save cluster" : "Register cluster"}
                </Button>
              </div>
            </form>

            {cluster && (
              <form
                onSubmit={handleAccessSubmit}
                className="space-y-4 rounded-lg border border-border p-4"
              >
                <div>
                  <div className="text-sm font-semibold">Project isolation</div>
                  <p className="mt-0.5 text-xs text-muted-foreground">
                    Each project gets a fixed RBD namespace and a cephx user scoped
                    to that namespace. Changing namespaces after images exist is not
                    supported.
                  </p>
                </div>

                <div className="space-y-2">
                  <Label htmlFor="ceph-project">Project</Label>
                  <select
                    id="ceph-project"
                    className={selectClassName}
                    value={selectedProjectId}
                    onChange={(event) => setSelectedProjectId(event.target.value)}
                    disabled={projectsLoading || accessPending}
                  >
                    {projectsLoading ? (
                      <option value="">Loading eligible projects…</option>
                    ) : projects.length === 0 ? (
                      <option value="">No manageable projects in this site</option>
                    ) : null}
                    {projects.map((project) => (
                      <option key={project.id} value={project.id}>
                        {project.name}
                      </option>
                    ))}
                  </select>
                </div>

                {projectPermissionsError || hierarchyQuery.error ? (
                  <div className="rounded-md border border-destructive/30 bg-destructive/5 p-3 text-sm text-destructive">
                    {errorMessage(
                      projectPermissionsError ?? hierarchyQuery.error,
                      "Failed to determine eligible projects"
                    )}
                  </div>
                ) : accessQuery.isLoading ? (
                  <div className="flex items-center gap-2 py-8 text-sm text-muted-foreground">
                    <Loader2 className="h-4 w-4 animate-spin" />
                    Loading project access…
                  </div>
                ) : accessQuery.error ? (
                  <div className="rounded-md border border-destructive/30 bg-destructive/5 p-3 text-sm text-destructive">
                    {errorMessage(accessQuery.error, "Failed to load project access")}
                  </div>
                ) : selectedProjectId ? (
                  <>
                    <div className="grid gap-4 sm:grid-cols-2">
                      <div className="space-y-2">
                        <Label htmlFor="ceph-project-client">Scoped client</Label>
                        <Input
                          id="ceph-project-client"
                          value={accessForm.clientName}
                          onChange={(event) =>
                            setAccessForm((current) => ({
                              ...current,
                              clientName: event.target.value,
                            }))
                          }
                          disabled={accessPending}
                          required
                        />
                      </div>
                      <div className="space-y-2">
                        <Label htmlFor="ceph-storage-pool-name">Strato pool name</Label>
                        <Input
                          id="ceph-storage-pool-name"
                          value={accessForm.storagePoolName}
                          onChange={(event) =>
                            setAccessForm((current) => ({
                              ...current,
                              storagePoolName: event.target.value,
                            }))
                          }
                          disabled={accessPending}
                          required
                        />
                      </div>
                    </div>
                    <div className="grid gap-4 sm:grid-cols-2">
                      <div className="space-y-2">
                        <Label htmlFor="ceph-rbd-pool">Ceph RBD pool</Label>
                        <Input
                          id="ceph-rbd-pool"
                          value={accessForm.cephPoolName}
                          onChange={(event) =>
                            setAccessForm((current) => ({
                              ...current,
                              cephPoolName: event.target.value,
                            }))
                          }
                          disabled={accessPending}
                          required
                        />
                      </div>
                      <div className="space-y-2">
                        <Label htmlFor="ceph-rbd-namespace">RBD namespace</Label>
                        <Input
                          id="ceph-rbd-namespace"
                          value={accessForm.namespace}
                          onChange={(event) =>
                            setAccessForm((current) => ({
                              ...current,
                              namespace: event.target.value,
                            }))
                          }
                          disabled={accessPending}
                          required
                        />
                      </div>
                    </div>
                    <div className="space-y-2">
                      <Label htmlFor="ceph-project-keyring">
                        Project keyring {access && "(leave blank to keep current)"}
                      </Label>
                      <textarea
                        id="ceph-project-keyring"
                        className={textareaClassName}
                        value={accessForm.keyring}
                        placeholder={`[${accessForm.clientName || "client.strato-project"}]\nkey = …\ncaps mon = "profile rbd"\ncaps mgr = "profile rbd pool=${accessForm.cephPoolName || "rbd"} namespace=${accessForm.namespace || "project"}"\ncaps osd = "profile rbd pool=${accessForm.cephPoolName || "rbd"} namespace=${accessForm.namespace || "project"}"`}
                        onChange={(event) =>
                          setAccessForm((current) => ({
                            ...current,
                            keyring: event.target.value,
                          }))
                        }
                        disabled={accessPending}
                        autoComplete="off"
                        spellCheck={false}
                      />
                      <p className="text-xs text-muted-foreground">
                        Paste the complete <code>ceph auth get</code> output. Strato
                        requires exactly <code>profile rbd</code> for monitors and
                        pool-and-namespace-scoped <code>profile rbd</code> caps for
                        both managers and OSDs. Create the namespace in Ceph before
                        saving this configuration; Strato does not create pools,
                        namespaces, users, or caps in a bring-your-own cluster.
                      </p>
                    </div>
                    <div className="flex justify-between gap-3">
                      <div>
                        {access && (
                          <Button
                            type="button"
                            variant="ghost"
                            className="text-destructive hover:text-destructive"
                            onClick={handleDeleteAccess}
                            disabled={accessPending}
                          >
                            <Trash2 className="h-4 w-4" />
                            Remove project access
                          </Button>
                        )}
                      </div>
                      <Button type="submit" disabled={accessPending}>
                        {accessPending && <Loader2 className="h-4 w-4 animate-spin" />}
                        {access ? "Save project access" : "Configure project"}
                      </Button>
                    </div>
                  </>
                ) : (
                  <p className="py-6 text-sm text-muted-foreground">
                    No project in this site scope is available for you to manage.
                  </p>
                )}
              </form>
            )}
          </div>
        )}

        <DialogFooter>
          <Button type="button" variant="outline" onClick={() => handleOpenChange(false)}>
            Close
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
