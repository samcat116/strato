"use client";

import { useState } from "react";
import { Database, Plus } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { QueryErrorNotice } from "@/components/ui/query-error-notice";
import { ResourceListControls, useResourceList } from "@/components/ui/resource-list-controls";
import { VolumeTable, CreateVolumeDialog } from "@/components/volumes";
import { useVMs, useVolumes, useInvalidateVolumes, usePermissions } from "@/lib/hooks";
import { useProjectContext } from "@/providers";

export default function VolumesPage() {
  const [createOpen, setCreateOpen] = useState(false);
  const { currentProject } = useProjectContext();
  const volumesQuery = useVolumes(currentProject?.id);
  const { data: volumes = [], isLoading } = volumesQuery;
  const { data: vms = [] } = useVMs();
  const invalidateVolumes = useInvalidateVolumes();
  const { permissions } = usePermissions(
    currentProject
      ? [{ key: "create", action: "volume:create", node: { type: "project", id: currentProject.id } }]
      : []
  );
  const list = useResourceList(volumes, (volume) => `${volume.name} ${volume.description ?? ""} ${volume.status} ${volume.volumeType}`);

  return (
    <div className="max-w-7xl mx-auto space-y-6">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-3">
          <Database className="h-8 w-8 text-blue-600" />
          <div>
            <h2 className="text-2xl font-semibold text-foreground">Volumes</h2>
            <p className="text-muted-foreground">
              {currentProject
                ? `Volumes in ${currentProject.name}`
                : "Manage block storage volumes for your virtual machines"}
            </p>
          </div>
        </div>
        {permissions.create && <Button
          className="bg-primary hover:bg-primary/90"
          onClick={() => setCreateOpen(true)}
        >
          <Plus className="h-4 w-4 mr-2" />
          Create Volume
        </Button>}
      </div>

      <QueryErrorNotice
        resource="volumes"
        error={volumesQuery.error}
        hasData={volumesQuery.data !== undefined}
        onRetry={() => void volumesQuery.refetch()}
      />

      <Card className="bg-card border-border">
        <CardHeader>
          <CardTitle className="text-lg font-semibold text-foreground">
            {currentProject ? currentProject.name : "All"} Volumes (
            {volumes.length})
          </CardTitle>
        </CardHeader>
        <CardContent>
          <ResourceListControls label="volumes" query={list.query} onQueryChange={list.setQuery} page={list.page} onPageChange={list.setPage} totalPages={list.totalPages} filteredCount={list.filteredCount} totalCount={list.totalCount} pageSize={list.pageSize} />
          <VolumeTable
            volumes={list.pageItems}
            vms={vms}
            isLoading={isLoading}
            onRefresh={invalidateVolumes}
          />
        </CardContent>
      </Card>

      <CreateVolumeDialog
        open={createOpen}
        onOpenChange={setCreateOpen}
        onCreated={invalidateVolumes}
      />
    </div>
  );
}
