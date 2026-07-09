"use client";

import { useState } from "react";
import { Camera, Plus } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { SnapshotTable, CreateSnapshotDialog } from "@/components/volumes";
import {
  useVolumes,
  useSnapshotsForVolumes,
  useInvalidateVolumes,
} from "@/lib/hooks";
import { useProjectContext } from "@/providers";

export default function SnapshotsPage() {
  const [createOpen, setCreateOpen] = useState(false);
  const { currentProject } = useProjectContext();
  const { data: volumes = [], isLoading: volumesLoading } = useVolumes(
    currentProject?.id
  );
  const { data: snapshots, isLoading: snapshotsLoading } =
    useSnapshotsForVolumes(volumes);
  const invalidateVolumes = useInvalidateVolumes();

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
        <Button
          className="bg-primary hover:bg-primary/90"
          onClick={() => setCreateOpen(true)}
        >
          <Plus className="h-4 w-4 mr-2" />
          Create Snapshot
        </Button>
      </div>

      <Card className="bg-card border-border">
        <CardHeader>
          <CardTitle className="text-lg font-semibold text-foreground">
            {currentProject ? currentProject.name : "All"} Snapshots (
            {snapshots.length})
          </CardTitle>
        </CardHeader>
        <CardContent>
          <SnapshotTable
            snapshots={snapshots}
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
