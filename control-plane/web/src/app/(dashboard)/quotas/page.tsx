"use client";

import { useMemo, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Building2, FolderTree, Boxes, Plus, Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Skeleton } from "@/components/ui/skeleton";
import { QuotaCard, QuotaDialog } from "@/components/quotas";
import { organizationsApi } from "@/lib/api/organizations";
import {
  useHierarchy,
  useDeleteQuota,
  quotaErrorMessage,
  type QuotaCreateTarget,
} from "@/lib/hooks";
import { useOrganization } from "@/providers";
import type {
  OrganizationHierarchy,
  OrganizationalUnitNode,
  ResourceQuota,
} from "@/types/api";
import { toast } from "sonner";

interface QuotaScope {
  key: string;
  icon: React.ReactNode;
  label: string;
  sublabel?: string;
  depth: number;
  quotas: ResourceQuota[];
  target: QuotaCreateTarget;
  environments?: string[];
}

// Flatten the hierarchy tree into a top-down, ordered list of scopes that can
// own quotas: organization -> OUs (depth-first) -> projects.
function collectScopes(
  hierarchy: OrganizationHierarchy,
  organizationId: string
): QuotaScope[] {
  const scopes: QuotaScope[] = [];
  const org = hierarchy.organization;

  scopes.push({
    key: `org-${org.id}`,
    icon: <Building2 className="h-4 w-4 text-blue-400" />,
    label: org.name,
    sublabel: "Organization",
    depth: 0,
    quotas: org.quotas,
    target: { scope: "organization", organizationId },
  });

  const addProject = (
    project: OrganizationHierarchy["organization"]["projects"][number],
    depth: number
  ) => {
    scopes.push({
      key: `project-${project.id}`,
      icon: <Boxes className="h-4 w-4 text-emerald-400" />,
      label: project.name,
      sublabel: "Project",
      depth,
      quotas: project.quotas,
      target: { scope: "project", projectId: project.id },
      environments: project.environments,
    });
  };

  const walkOU = (ou: OrganizationalUnitNode, depth: number) => {
    scopes.push({
      key: `ou-${ou.id}`,
      icon: <FolderTree className="h-4 w-4 text-purple-400" />,
      label: ou.name,
      sublabel: "Organizational Unit",
      depth,
      quotas: ou.quotas,
      target: { scope: "ou", organizationId, ouId: ou.id },
    });
    ou.projects.forEach((p) => addProject(p, depth + 1));
    ou.childOUs.forEach((child) => walkOU(child, depth + 1));
  };

  org.organizationalUnits.forEach((ou) => walkOU(ou, 1));
  org.projects.forEach((p) => addProject(p, 1));

  return scopes;
}

export default function QuotasPage() {
  const { currentOrg } = useOrganization();
  const orgId = currentOrg?.id;

  const { data: hierarchy, isLoading, error } = useHierarchy(orgId);
  const deleteQuota = useDeleteQuota();

  // Fetch org detail for the caller's role (list responses omit it).
  const { data: orgDetail } = useQuery({
    queryKey: ["organization", orgId],
    queryFn: () => organizationsApi.get(orgId!),
    enabled: !!orgId,
  });
  const canManage = orgDetail?.userRole === "admin";

  const [dialogOpen, setDialogOpen] = useState(false);
  const [dialogSeq, setDialogSeq] = useState(0);
  const [editingQuota, setEditingQuota] = useState<ResourceQuota | undefined>();
  const [createTarget, setCreateTarget] = useState<QuotaCreateTarget>();
  const [dialogScopeLabel, setDialogScopeLabel] = useState("");
  const [dialogEnvironments, setDialogEnvironments] = useState<string[]>();
  const [pendingDelete, setPendingDelete] = useState<ResourceQuota>();

  const scopes = useMemo(
    () => (hierarchy && orgId ? collectScopes(hierarchy, orgId) : []),
    [hierarchy, orgId]
  );

  const openCreate = (scope: QuotaScope) => {
    setEditingQuota(undefined);
    setCreateTarget(scope.target);
    setDialogScopeLabel(scope.label);
    setDialogEnvironments(scope.environments);
    setDialogSeq((n) => n + 1);
    setDialogOpen(true);
  };

  const openEdit = (scope: QuotaScope, quota: ResourceQuota) => {
    setEditingQuota(quota);
    setCreateTarget(scope.target);
    setDialogScopeLabel(scope.label);
    setDialogEnvironments(scope.environments);
    setDialogSeq((n) => n + 1);
    setDialogOpen(true);
  };

  const confirmDelete = async () => {
    if (!pendingDelete) return;
    try {
      await deleteQuota.mutateAsync(pendingDelete.id);
      toast.success(`Quota "${pendingDelete.name}" deleted`);
      setPendingDelete(undefined);
    } catch (err) {
      toast.error(quotaErrorMessage(err, "Failed to delete quota"));
    }
  };

  if (!orgId) {
    return (
      <div className="max-w-5xl mx-auto text-center py-12">
        <p className="text-gray-400">No organization selected</p>
      </div>
    );
  }

  return (
    <div className="max-w-5xl mx-auto space-y-6">
      <div>
        <h2 className="text-2xl font-semibold text-gray-100">
          Resource Quotas
        </h2>
        <p className="text-gray-400">
          Set and monitor resource limits across your organization, units, and
          projects
        </p>
      </div>

      {isLoading ? (
        <div className="space-y-4">
          <Skeleton className="h-40 w-full bg-gray-700" />
          <Skeleton className="h-40 w-full bg-gray-700" />
        </div>
      ) : error ? (
        <Card className="bg-gray-800 border-gray-700">
          <CardContent className="py-12 text-center text-gray-400">
            Failed to load quotas. You may not have access to this
            organization&apos;s hierarchy.
          </CardContent>
        </Card>
      ) : (
        <div className="space-y-4">
          {scopes.map((scope) => (
            <Card
              key={scope.key}
              className="bg-gray-800 border-gray-700"
              style={{ marginLeft: scope.depth * 16 }}
            >
              <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-3">
                <div className="flex items-center gap-2 min-w-0">
                  {scope.icon}
                  <div className="min-w-0">
                    <CardTitle className="text-base font-semibold text-gray-100 truncate">
                      {scope.label}
                    </CardTitle>
                    {scope.sublabel && (
                      <p className="text-xs text-gray-500">{scope.sublabel}</p>
                    )}
                  </div>
                </div>
                {canManage && (
                  <Button
                    size="sm"
                    variant="outline"
                    className="border-gray-600 text-gray-300 hover:bg-gray-700 shrink-0"
                    onClick={() => openCreate(scope)}
                  >
                    <Plus className="h-4 w-4 mr-1" />
                    Add Quota
                  </Button>
                )}
              </CardHeader>
              <CardContent>
                {scope.quotas.length === 0 ? (
                  <p className="text-sm text-gray-500">
                    No quotas defined at this level.
                  </p>
                ) : (
                  <div className="space-y-3">
                    {scope.quotas.map((quota) => (
                      <QuotaCard
                        key={quota.id}
                        quota={quota}
                        canManage={canManage}
                        onEdit={(q) => openEdit(scope, q)}
                        onDelete={(q) => setPendingDelete(q)}
                      />
                    ))}
                  </div>
                )}
              </CardContent>
            </Card>
          ))}
        </div>
      )}

      <QuotaDialog
        key={dialogSeq}
        open={dialogOpen}
        onOpenChange={setDialogOpen}
        target={createTarget}
        quota={editingQuota}
        scopeLabel={dialogScopeLabel}
        environments={dialogEnvironments}
      />

      <Dialog
        open={!!pendingDelete}
        onOpenChange={(open) => !open && setPendingDelete(undefined)}
      >
        <DialogContent className="bg-gray-800 border-gray-700 text-gray-100">
          <DialogHeader>
            <DialogTitle>Delete Quota</DialogTitle>
            <DialogDescription className="text-gray-400">
              Delete quota{" "}
              <span className="text-gray-200">
                &quot;{pendingDelete?.name}&quot;
              </span>
              ? This cannot be undone. Quotas with active reservations cannot be
              deleted.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button
              variant="outline"
              onClick={() => setPendingDelete(undefined)}
              className="border-gray-600 text-gray-300 hover:bg-gray-700"
              disabled={deleteQuota.isPending}
            >
              Cancel
            </Button>
            <Button
              className="bg-red-600 hover:bg-red-700"
              onClick={confirmDelete}
              disabled={deleteQuota.isPending}
            >
              {deleteQuota.isPending ? (
                <>
                  <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                  Deleting...
                </>
              ) : (
                "Delete"
              )}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
