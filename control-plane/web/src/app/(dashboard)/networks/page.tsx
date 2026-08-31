"use client";

import { useState } from "react";
import { Network as NetworkIcon, Plus } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { QueryErrorNotice } from "@/components/ui/query-error-notice";
import { ResourceListControls, useResourceList } from "@/components/ui/resource-list-controls";
import { ProjectRequiredState } from "@/components/ui/project-required-state";
import {
  NetworkTable,
  CreateNetworkDialog,
  EditNetworkDialog,
  NetworkACLDialog,
} from "@/components/networks";
import { useNetworks, useInvalidateNetworks, usePermissions } from "@/lib/hooks";
import { useProjectContext } from "@/providers";
import type { Network } from "@/types/api";

export default function NetworksPage() {
  const [createOpen, setCreateOpen] = useState(false);
  const [editing, setEditing] = useState<Network | null>(null);
  const [aclSelection, setACLSelection] = useState<{
    network: Network;
    canManage: boolean;
  } | null>(null);
  const { currentProject, isLoading: projectsLoading } = useProjectContext();
  const networksQuery = useNetworks(currentProject?.id);
  const { data: networks = [], isLoading } = networksQuery;
  const invalidateNetworks = useInvalidateNetworks();
  const { permissions } = usePermissions(
    currentProject
      ? [{ key: "create", action: "network:create", node: { type: "project", id: currentProject.id } }]
      : []
  );
  const list = useResourceList(networks, (network) => `${network.name} ${network.subnet} ${network.subnet6 ?? ""}`);

  return (
    <div className="max-w-7xl mx-auto space-y-6">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-3">
          <NetworkIcon className="h-8 w-8 text-blue-600" />
          <div>
            <h2 className="text-2xl font-semibold text-foreground">Networks</h2>
            <p className="text-muted-foreground">
              {currentProject
                ? `Networks available in ${currentProject.name}`
                : "Manage the logical networks your VMs attach to"}
            </p>
          </div>
        </div>
        {permissions.create && <Button
          className="bg-primary hover:bg-primary/90"
          onClick={() => setCreateOpen(true)}
        >
          <Plus className="h-4 w-4 mr-2" />
          Create Network
        </Button>}
      </div>

      <QueryErrorNotice
        resource="networks"
        error={networksQuery.error}
        hasData={networksQuery.data !== undefined}
        onRetry={() => void networksQuery.refetch()}
      />

      <Card className="bg-card border-border">
        <CardHeader>
          <CardTitle className="text-lg font-semibold text-foreground">
            {projectsLoading
              ? "Loading project…"
              : currentProject
                ? `${currentProject.name} Networks (${networks.length})`
                : "Networks"
            }
          </CardTitle>
        </CardHeader>
        <CardContent>
          {!projectsLoading && !currentProject ? (
            <ProjectRequiredState resource="Networks" />
          ) : (
            <>
              <ResourceListControls label="networks" query={list.query} onQueryChange={list.setQuery} page={list.page} onPageChange={list.setPage} totalPages={list.totalPages} filteredCount={list.filteredCount} totalCount={list.totalCount} pageSize={list.pageSize} />
              <NetworkTable
                networks={list.pageItems}
                isLoading={isLoading || projectsLoading}
                onRefresh={invalidateNetworks}
                onEdit={setEditing}
                onManageACL={(network, canManage) =>
                  setACLSelection({ network, canManage })
                }
              />
            </>
          )}
        </CardContent>
      </Card>

      <CreateNetworkDialog
        open={createOpen}
        onOpenChange={setCreateOpen}
        onCreated={invalidateNetworks}
      />

      <EditNetworkDialog
        network={editing}
        open={editing !== null}
        onOpenChange={(open) => {
          if (!open) setEditing(null);
        }}
        onUpdated={invalidateNetworks}
      />

      <NetworkACLDialog
        network={aclSelection?.network ?? null}
        canManage={aclSelection?.canManage ?? false}
        open={aclSelection !== null}
        onOpenChange={(open) => {
          if (!open) setACLSelection(null);
        }}
      />
    </div>
  );
}
