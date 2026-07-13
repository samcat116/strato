"use client";

import { useMemo, useState } from "react";
import { Plus } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { SandboxTable, CreateSandboxDialog } from "@/components/sandboxes";
import { useSandboxes, useInvalidateSandboxes } from "@/lib/hooks";
import { useProjectContext } from "@/providers";

export default function SandboxesPage() {
  const [createOpen, setCreateOpen] = useState(false);
  const { data: sandboxes = [], isLoading } = useSandboxes();
  const invalidateSandboxes = useInvalidateSandboxes();

  // Scope the list to the project selected in the header switcher, mirroring
  // the VMs page: an active project narrows to its sandboxes; otherwise all.
  const { currentProject } = useProjectContext();
  const scopedSandboxes = useMemo(() => {
    if (!currentProject) return sandboxes;
    return sandboxes.filter((s) => s.projectId === currentProject.id);
  }, [sandboxes, currentProject]);

  return (
    <div className="max-w-7xl mx-auto space-y-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-2xl font-semibold text-foreground">Sandboxes</h2>
          <p className="text-muted-foreground">
            {currentProject
              ? `Sandboxes in ${currentProject.name}`
              : "OCI-image microVMs for short-lived workloads"}
          </p>
        </div>
        <Button
          className="bg-primary hover:bg-primary/90"
          onClick={() => setCreateOpen(true)}
        >
          <Plus className="h-4 w-4 mr-2" />
          Create Sandbox
        </Button>
      </div>

      {/* Sandbox List */}
      <Card className="bg-card border-border">
        <CardHeader>
          <CardTitle className="text-lg font-semibold text-foreground">
            {currentProject ? currentProject.name : "All"} Sandboxes (
            {scopedSandboxes.length})
          </CardTitle>
        </CardHeader>
        <CardContent>
          <SandboxTable
            sandboxes={scopedSandboxes}
            isLoading={isLoading}
            onRefresh={invalidateSandboxes}
          />
        </CardContent>
      </Card>

      {/* Create Sandbox Dialog */}
      <CreateSandboxDialog
        open={createOpen}
        onOpenChange={setCreateOpen}
        onCreated={invalidateSandboxes}
      />
    </div>
  );
}
