"use client";

import { useState } from "react";
import { Camera, Plus } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { QueryErrorNotice } from "@/components/ui/query-error-notice";
import { ResourceListControls, useResourceList } from "@/components/ui/resource-list-controls";
import { SnapshotTable, CreateSnapshotDialog } from "@/components/volumes";
import {
  useVolumes,
  useProjectVolumeSnapshots,
  useInvalidateVolumes,
  usePermissions,
} from "@/lib/hooks";
import { useProjectContext } from "@/providers";

export default function SnapshotsPage() {
  const [createOpen, setCreateOpen] = useState(false);
  const { currentProject } = useProjectContext();
  const volumesQuery = useVolumes(currentProject?.id);
  const snapshotsQuery = useProjectVolumeSnapshots(currentProject?.id);
  const { data: volumes = [], isLoading: volumesLoading } = volumesQuery;
  const { data: snapshots = [], isLoading: snapshotsLoading } = snapshotsQuery;
  const invalidateVolumes = useInvalidateVolumes();
  const { permissions } = usePermissions(
    volumes
      .filter((volume) => volume.id)
      .map((volume) => ({
        key: `snapshot_${volume.id}`,
        action: "volume:snapshot",
        node: { type: "volume", id: volume.id! },
      }))
  );
  const canCreateSnapshot = Object.values(permissions).some(Boolean);
  const list = useResourceList(snapshots, (snapshot) => `${snapshot.name} ${snapshot.description ?? ""} ${snapshot.status}`);

  return (
    <div className="max-w-7xl mx-auto space-y-6">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-3">
          <Camera className="h-8 w-8 text-blue-600" />
          <div>
            <h2 className="text-2xl font-semibold text-foreground">Snapshots</h2>
            <p className="text-muted-foreground">
              {currentProject
                ? `Volume snapshots in ${currentProject.name}`
                : "Point-in-time copies of your volumes"}
            </p>
          </div>
        </div>
        {canCreateSnapshot && <Button
          className="bg-primary hover:bg-primary/90"
          onClick={() => setCreateOpen(true)}
        >
          <Plus className="h-4 w-4 mr-2" />
          Create Snapshot
        </Button>}
      </div>

      <QueryErrorNotice
        resource="volume snapshots"
        error={snapshotsQuery.error ?? volumesQuery.error}
        hasData={
          snapshotsQuery.data !== undefined && volumesQuery.data !== undefined
        }
        onRetry={() => {
          void snapshotsQuery.refetch();
          void volumesQuery.refetch();
        }}
      />

      <Card className="bg-card border-border">
        <CardHeader>
          <CardTitle className="text-lg font-semibold text-foreground">
            {currentProject ? currentProject.name : "All"} Snapshots (
            {snapshots.length})
          </CardTitle>
        </CardHeader>
        <CardContent>
          <ResourceListControls label="snapshots" query={list.query} onQueryChange={list.setQuery} page={list.page} onPageChange={list.setPage} totalPages={list.totalPages} filteredCount={list.filteredCount} totalCount={list.totalCount} pageSize={list.pageSize} />
          <SnapshotTable
            snapshots={list.pageItems}
            volumes={volumes}
            isLoading={volumesLoading || snapshotsLoading}
            onRefresh={invalidateVolumes}
          />
        </CardContent>
      </Card>

      <CreateSnapshotDialog
        volumes={volumes}
        open={createOpen}
        onOpenChange={setCreateOpen}
        onSuccess={invalidateVolumes}
      />
    </div>
  );
}
