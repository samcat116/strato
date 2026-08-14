"use client";

import { useMemo, useState } from "react";
import { Plus } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { QueryErrorNotice } from "@/components/ui/query-error-notice";
import { ResourceListControls, useResourceList } from "@/components/ui/resource-list-controls";
import { VMTable, CreateVMDialog } from "@/components/vms";
import { useVMs, useInvalidateVMs, usePermissions } from "@/lib/hooks";
import { useProjectContext } from "@/providers";

export default function VMsPage() {
  const [createVMOpen, setCreateVMOpen] = useState(false);
  const vmsQuery = useVMs();
  const { data: vms = [], isLoading } = vmsQuery;
  const invalidateVMs = useInvalidateVMs();

  // Scope the list to the project selected in the header switcher. When a
  // project is active, only its VMs are shown; otherwise fall back to all.
  const { currentProject } = useProjectContext();
  const { permissions } = usePermissions(
    currentProject
      ? [{ key: "create", action: "vm:create", node: { type: "project", id: currentProject.id } }]
      : []
  );
  const scopedVMs = useMemo(() => {
    if (!currentProject) return vms;
    return vms.filter((vm) => vm.projectId === currentProject.id);
  }, [vms, currentProject]);
  const list = useResourceList(scopedVMs, (vm) => `${vm.name} ${vm.description ?? ""} ${vm.status}`);

  return (
    <div className="max-w-7xl mx-auto space-y-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-2xl font-semibold text-foreground">
            Virtual Machines
          </h2>
          <p className="text-muted-foreground">
            {currentProject
              ? `VMs in ${currentProject.name}`
              : "Manage and monitor your virtual machines"}
          </p>
        </div>
        {permissions.create && <Button
          className="bg-primary hover:bg-primary/90"
          onClick={() => setCreateVMOpen(true)}
        >
          <Plus className="h-4 w-4 mr-2" />
          Create VM
        </Button>}
      </div>

      <QueryErrorNotice
        resource="virtual machines"
        error={vmsQuery.error}
        hasData={vmsQuery.data !== undefined}
        onRetry={() => void vmsQuery.refetch()}
      />

      {/* VM List */}
      <Card className="bg-card border-border">
        <CardHeader>
          <CardTitle className="text-lg font-semibold text-foreground">
            {currentProject ? currentProject.name : "All"} Virtual Machines (
            {scopedVMs.length})
          </CardTitle>
        </CardHeader>
        <CardContent>
          <ResourceListControls label="virtual machines" query={list.query} onQueryChange={list.setQuery} page={list.page} onPageChange={list.setPage} totalPages={list.totalPages} filteredCount={list.filteredCount} totalCount={list.totalCount} pageSize={list.pageSize} />
          <VMTable
            vms={list.pageItems}
            isLoading={isLoading}
            onRefresh={invalidateVMs}
          />
        </CardContent>
      </Card>

      {/* Create VM Dialog */}
      <CreateVMDialog
        open={createVMOpen}
        onOpenChange={setCreateVMOpen}
        onCreated={invalidateVMs}
      />
    </div>
  );
}
