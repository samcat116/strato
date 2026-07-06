"use client";

import { useState } from "react";
import { Network as NetworkIcon, Plus } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { NetworkTable, CreateNetworkDialog } from "@/components/networks";
import { useNetworks, useInvalidateNetworks } from "@/lib/hooks";
import { useProjectContext } from "@/providers";

export default function NetworksPage() {
  const [createOpen, setCreateOpen] = useState(false);
  const { currentProject } = useProjectContext();
  const { data: networks = [], isLoading } = useNetworks(currentProject?.id);
  const invalidateNetworks = useInvalidateNetworks();

  return (
    <div className="max-w-7xl mx-auto space-y-6">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-3">
          <NetworkIcon className="h-8 w-8 text-blue-400" />
          <div>
            <h2 className="text-2xl font-semibold text-gray-100">Networks</h2>
            <p className="text-gray-400">
              {currentProject
                ? `Networks available in ${currentProject.name}`
                : "Manage the logical networks your VMs attach to"}
            </p>
          </div>
        </div>
        <Button
          className="bg-blue-600 hover:bg-blue-700"
          onClick={() => setCreateOpen(true)}
        >
          <Plus className="h-4 w-4 mr-2" />
          Create Network
        </Button>
      </div>

      <Card className="bg-gray-800 border-gray-700">
        <CardHeader>
          <CardTitle className="text-lg font-semibold text-gray-100">
            {currentProject ? currentProject.name : "All"} Networks (
            {networks.length})
          </CardTitle>
        </CardHeader>
        <CardContent>
          <NetworkTable
            networks={networks}
            isLoading={isLoading}
            onRefresh={invalidateNetworks}
          />
        </CardContent>
      </Card>

      <CreateNetworkDialog
        open={createOpen}
        onOpenChange={setCreateOpen}
        onCreated={invalidateNetworks}
      />
    </div>
  );
}
