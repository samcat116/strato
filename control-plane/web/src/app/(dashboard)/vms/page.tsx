"use client";

import { useState } from "react";
import { Plus } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { VMTable, CreateVMDialog } from "@/components/vms";
import { useVMs, useInvalidateVMs } from "@/lib/hooks";

export default function VMsPage() {
  const [createVMOpen, setCreateVMOpen] = useState(false);
  const { data: vms = [], isLoading } = useVMs();
  const invalidateVMs = useInvalidateVMs();

  return (
    <div className="max-w-7xl mx-auto space-y-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-2xl font-semibold text-gray-100">
            Virtual Machines
          </h2>
          <p className="text-gray-400">
            Manage and monitor your virtual machines
          </p>
        </div>
        <Button
          className="bg-blue-600 hover:bg-blue-700"
          onClick={() => setCreateVMOpen(true)}
        >
          <Plus className="h-4 w-4 mr-2" />
          Create VM
        </Button>
      </div>

      {/* VM List */}
      <Card className="bg-gray-800 border-gray-700">
        <CardHeader>
          <CardTitle className="text-lg font-semibold text-gray-100">
            All Virtual Machines ({vms.length})
          </CardTitle>
        </CardHeader>
        <CardContent>
          <VMTable vms={vms} isLoading={isLoading} onRefresh={invalidateVMs} />
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
