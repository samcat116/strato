"use client";

import { useState } from "react";
import { Plus } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { QueryErrorNotice } from "@/components/ui/query-error-notice";
import { ResourceListControls, useResourceList } from "@/components/ui/resource-list-controls";
import { AgentTable, CreateEnrollmentDialog } from "@/components/agents";
import { useAgents, useInvalidateAgents, usePermissions } from "@/lib/hooks";
import { useOrganization } from "@/providers";

export default function AgentsPage() {
  const [createEnrollmentOpen, setCreateEnrollmentOpen] = useState(false);
  const agentsQuery = useAgents();
  const { data: agents = [], isLoading } = agentsQuery;
  const invalidateAgents = useInvalidateAgents();
  const { currentOrg } = useOrganization();
  const { permissions } = usePermissions(
    currentOrg
      ? [{ key: "create", action: "agent:manage", node: { type: "organization", id: currentOrg.id } }]
      : []
  );

  const onlineCount = agents.filter((a) => a.isOnline).length;
  const offlineCount = agents.filter((a) => !a.isOnline).length;
  const list = useResourceList(agents, (agent) => `${agent.name} ${agent.hostname} ${agent.status}`);

  return (
    <div className="max-w-7xl mx-auto space-y-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-2xl font-semibold text-foreground">
            Compute Agents
          </h2>
          <p className="text-muted-foreground">Manage your hypervisor nodes</p>
        </div>
        {permissions.create && <Button
          className="bg-primary hover:bg-primary/90"
          onClick={() => setCreateEnrollmentOpen(true)}
        >
          <Plus className="h-4 w-4 mr-2" />
          Add Agent
        </Button>}
      </div>

      <QueryErrorNotice
        resource="compute agents"
        error={agentsQuery.error}
        hasData={agentsQuery.data !== undefined}
        onRetry={() => void agentsQuery.refetch()}
      />

      {/* Stats */}
      <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
        <Card className="bg-card border-border">
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium text-muted-foreground">
              Total Agents
            </CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-bold text-foreground">
              {agents.length}
            </div>
          </CardContent>
        </Card>
        <Card className="bg-card border-border">
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium text-muted-foreground">
              Online
            </CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-bold text-green-600">
              {onlineCount}
            </div>
          </CardContent>
        </Card>
        <Card className="bg-card border-border">
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium text-muted-foreground">
              Offline
            </CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-bold text-red-600">{offlineCount}</div>
          </CardContent>
        </Card>
      </div>

      {/* Agent List */}
      <Card className="bg-card border-border">
        <CardHeader>
          <CardTitle className="text-lg font-semibold text-foreground">
            Registered Agents
          </CardTitle>
        </CardHeader>
        <CardContent>
          <ResourceListControls label="agents" query={list.query} onQueryChange={list.setQuery} page={list.page} onPageChange={list.setPage} totalPages={list.totalPages} filteredCount={list.filteredCount} totalCount={list.totalCount} pageSize={list.pageSize} />
          <AgentTable agents={list.pageItems} isLoading={isLoading} />
        </CardContent>
      </Card>

      {/* Create Enrollment Dialog */}
      <CreateEnrollmentDialog
        open={createEnrollmentOpen}
        onOpenChange={setCreateEnrollmentOpen}
        onCreated={invalidateAgents}
      />
    </div>
  );
}
