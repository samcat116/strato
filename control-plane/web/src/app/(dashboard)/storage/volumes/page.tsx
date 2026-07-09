"use client";

import { useState } from "react";
import { Database, Plus } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { VolumeTable, CreateVolumeDialog } from "@/components/volumes";
import { useVMs, useVolumes, useInvalidateVolumes } from "@/lib/hooks";
import { useProjectContext } from "@/providers";

export default function VolumesPage() {
  const [createOpen, setCreateOpen] = useState(false);
  const { currentProject } = useProjectContext();
  const { data: volumes = [], isLoading } = useVolumes(currentProject?.id);
  const { data: vms = [] } = useVMs();
  const invalidateVolumes = useInvalidateVolumes();

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
        <Button
          className="bg-primary hover:bg-primary/90"
          onClick={() => setCreateOpen(true)}
        >
          <Plus className="h-4 w-4 mr-2" />
          Create Volume
        </Button>
      </div>

      <Card className="bg-card border-border">
        <CardHeader>
          <CardTitle className="text-lg font-semibold text-foreground">
            {currentProject ? currentProject.name : "All"} Volumes (
            {volumes.length})
          </CardTitle>
        </CardHeader>
        <CardContent>
          <VolumeTable
            volumes={volumes}
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
