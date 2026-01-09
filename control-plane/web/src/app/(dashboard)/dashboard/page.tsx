"use client";

import { useState } from "react";
import { Plus } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { VMTable, CreateVMDialog } from "@/components/vms";
import { useVMs, useInvalidateVMs } from "@/lib/hooks";

export default function DashboardPage() {
  const [createVMOpen, setCreateVMOpen] = useState(false);
  const { data: vms = [], isLoading } = useVMs();
  const invalidateVMs = useInvalidateVMs();

  return (
    <div className="max-w-7xl mx-auto space-y-6">
      {/* Header */}
      <div>
        <h2 className="text-2xl font-semibold text-gray-100">Dashboard</h2>
        <p className="text-gray-400">Manage your virtual infrastructure</p>
      </div>

      {/* Stats */}
      <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
        <Card className="bg-gray-800 border-gray-700">
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium text-gray-400">
              Total VMs
            </CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-bold text-gray-100">{vms.length}</div>
          </CardContent>
        </Card>
        <Card className="bg-gray-800 border-gray-700">
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium text-gray-400">
              Running
            </CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-bold text-green-400">
              {vms.filter((vm) => vm.status === "running").length}
            </div>
          </CardContent>
        </Card>
        <Card className="bg-gray-800 border-gray-700">
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium text-gray-400">
              Stopped
            </CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-bold text-red-400">
              {vms.filter((vm) => vm.status === "shutdown").length}
            </div>
          </CardContent>
        </Card>
      </div>

      {/* VM List */}
      <Card className="bg-gray-800 border-gray-700">
        <CardHeader className="flex flex-row items-center justify-between">
          <CardTitle className="text-lg font-semibold text-gray-100">
            Virtual Machines
          </CardTitle>
          <Button
            className="bg-blue-600 hover:bg-blue-700"
            onClick={() => setCreateVMOpen(true)}
          >
            <Plus className="h-4 w-4 mr-2" />
            Create VM
          </Button>
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
