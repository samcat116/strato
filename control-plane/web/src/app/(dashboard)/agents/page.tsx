"use client";

import { useState } from "react";
import { Plus } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { AgentTable, CreateTokenDialog } from "@/components/agents";
import { useAgents, useInvalidateAgents } from "@/lib/hooks";

export default function AgentsPage() {
  const [createTokenOpen, setCreateTokenOpen] = useState(false);
  const { data: agents = [], isLoading } = useAgents();
  const invalidateAgents = useInvalidateAgents();

  const onlineCount = agents.filter((a) => a.isOnline).length;
  const offlineCount = agents.filter((a) => !a.isOnline).length;

  return (
    <div className="max-w-7xl mx-auto space-y-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-2xl font-semibold text-gray-100">
            Compute Agents
          </h2>
          <p className="text-gray-400">Manage your hypervisor nodes</p>
        </div>
        <Button
          className="bg-blue-600 hover:bg-blue-700"
          onClick={() => setCreateTokenOpen(true)}
        >
          <Plus className="h-4 w-4 mr-2" />
          Add Agent
        </Button>
      </div>

      {/* Stats */}
      <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
        <Card className="bg-gray-800 border-gray-700">
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium text-gray-400">
              Total Agents
            </CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-bold text-gray-100">
              {agents.length}
            </div>
          </CardContent>
        </Card>
        <Card className="bg-gray-800 border-gray-700">
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium text-gray-400">
              Online
            </CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-bold text-green-400">
              {onlineCount}
            </div>
          </CardContent>
        </Card>
        <Card className="bg-gray-800 border-gray-700">
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium text-gray-400">
              Offline
            </CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-bold text-red-400">{offlineCount}</div>
          </CardContent>
        </Card>
      </div>

      {/* Agent List */}
      <Card className="bg-gray-800 border-gray-700">
        <CardHeader>
          <CardTitle className="text-lg font-semibold text-gray-100">
            Registered Agents
          </CardTitle>
        </CardHeader>
        <CardContent>
          <AgentTable agents={agents} isLoading={isLoading} />
        </CardContent>
      </Card>

      {/* Create Token Dialog */}
      <CreateTokenDialog
        open={createTokenOpen}
        onOpenChange={setCreateTokenOpen}
        onCreated={invalidateAgents}
      />
    </div>
  );
}
