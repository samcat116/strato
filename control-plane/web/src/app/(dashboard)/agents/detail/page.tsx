"use client";

import { useSearchParams } from "next/navigation";
import Link from "next/link";
import {
  ArrowLeft,
  Cpu,
  HardDrive,
  MemoryStick,
  Clock,
  Server,
  Activity,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { Badge } from "@/components/ui/badge";
import { useAgent } from "@/lib/hooks";

export default function AgentDetailPage() {
  const searchParams = useSearchParams();
  const id = searchParams.get("id") || "";
  const { data: agent, isLoading, error } = useAgent(id);

  if (!id) {
    return (
      <div className="max-w-4xl mx-auto">
        <div className="text-center py-12">
          <p className="text-gray-400 mb-4">No Agent ID provided</p>
          <Link href="/agents">
            <Button variant="outline" className="border-gray-600">
              <ArrowLeft className="h-4 w-4 mr-2" />
              Back to Agents
            </Button>
          </Link>
        </div>
      </div>
    );
  }

  if (isLoading) {
    return (
      <div className="max-w-4xl mx-auto space-y-6">
        <Skeleton className="h-8 w-48 bg-gray-700" />
        <Skeleton className="h-64 w-full bg-gray-700" />
      </div>
    );
  }

  if (error || !agent) {
    return (
      <div className="max-w-4xl mx-auto">
        <div className="text-center py-12">
          <p className="text-gray-400 mb-4">Agent not found or failed to load</p>
          <Link href="/agents">
            <Button variant="outline" className="border-gray-600">
              <ArrowLeft className="h-4 w-4 mr-2" />
              Back to Agents
            </Button>
          </Link>
        </div>
      </div>
    );
  }

  // Memory values are in bytes
  const formatMemory = (bytes: number) => {
    const gb = bytes / 1024 / 1024 / 1024;
    if (gb >= 1) {
      return `${gb.toFixed(0)} GB`;
    }
    const mb = bytes / 1024 / 1024;
    return `${Math.round(mb)} MB`;
  };

  // Disk values are in bytes
  const formatDisk = (bytes: number) => {
    const gb = bytes / 1024 / 1024 / 1024;
    if (gb >= 1024) {
      return `${(gb / 1024).toFixed(0)} TB`;
    }
    return `${gb.toFixed(0)} GB`;
  };

  return (
    <div className="max-w-4xl mx-auto space-y-6">
      {/* Header */}
      <div className="flex items-start justify-between">
        <div>
          <Link
            href="/agents"
            className="text-sm text-gray-400 hover:text-gray-200 flex items-center mb-2"
          >
            <ArrowLeft className="h-4 w-4 mr-1" />
            Back to Agents
          </Link>
          <div className="flex items-center gap-3">
            <h2 className="text-2xl font-semibold text-gray-100">{agent.name}</h2>
            <Badge
              variant={agent.isOnline ? "default" : "secondary"}
              className={agent.isOnline ? "bg-green-600" : "bg-gray-600"}
            >
              {agent.isOnline ? "Online" : "Offline"}
            </Badge>
          </div>
          <p className="text-gray-400 mt-1">{agent.hostname}</p>
        </div>
      </div>

      {/* Resources */}
      <div className="grid grid-cols-1 md:grid-cols-4 gap-4">
        <Card className="bg-gray-800 border-gray-700">
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium text-gray-400 flex items-center gap-2">
              <Cpu className="h-4 w-4" />
              CPU
            </CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-xl font-bold text-gray-100">
              {agent.resources.availableCPU} / {agent.resources.totalCPU}
            </div>
            <p className="text-sm text-gray-500">cores available</p>
          </CardContent>
        </Card>
        <Card className="bg-gray-800 border-gray-700">
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium text-gray-400 flex items-center gap-2">
              <MemoryStick className="h-4 w-4" />
              Memory
            </CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-xl font-bold text-gray-100">
              {formatMemory(agent.resources.availableMemory)}
            </div>
            <p className="text-sm text-gray-500">
              of {formatMemory(agent.resources.totalMemory)} available
            </p>
          </CardContent>
        </Card>
        <Card className="bg-gray-800 border-gray-700">
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium text-gray-400 flex items-center gap-2">
              <HardDrive className="h-4 w-4" />
              Disk
            </CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-xl font-bold text-gray-100">
              {formatDisk(agent.resources.availableDisk)}
            </div>
            <p className="text-sm text-gray-500">
              of {formatDisk(agent.resources.totalDisk)} available
            </p>
          </CardContent>
        </Card>
        <Card className="bg-gray-800 border-gray-700">
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium text-gray-400 flex items-center gap-2">
              <Clock className="h-4 w-4" />
              Last Heartbeat
            </CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-sm font-medium text-gray-100">
              {agent.lastHeartbeat
                ? new Date(agent.lastHeartbeat).toLocaleDateString()
                : "Never"}
            </div>
            <p className="text-sm text-gray-500">
              {agent.lastHeartbeat
                ? new Date(agent.lastHeartbeat).toLocaleTimeString()
                : "-"}
            </p>
          </CardContent>
        </Card>
      </div>

      {/* Details */}
      <Card className="bg-gray-800 border-gray-700">
        <CardHeader>
          <CardTitle className="text-lg font-semibold text-gray-100">
            Details
          </CardTitle>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="grid grid-cols-2 gap-4 text-sm">
            <div>
              <p className="text-gray-400">ID</p>
              <p className="text-gray-100 font-mono">{agent.id}</p>
            </div>
            <div>
              <p className="text-gray-400">Version</p>
              <p className="text-gray-100">{agent.version}</p>
            </div>
            <div>
              <p className="text-gray-400">Hostname</p>
              <p className="text-gray-100">{agent.hostname}</p>
            </div>
            <div>
              <p className="text-gray-400">Registered</p>
              <p className="text-gray-100">
                {new Date(agent.createdAt).toLocaleString()}
              </p>
            </div>
          </div>
        </CardContent>
      </Card>

      {/* Capabilities */}
      {agent.capabilities && agent.capabilities.length > 0 && (
        <Card className="bg-gray-800 border-gray-700">
          <CardHeader>
            <CardTitle className="text-lg font-semibold text-gray-100 flex items-center gap-2">
              <Activity className="h-5 w-5" />
              Capabilities
            </CardTitle>
          </CardHeader>
          <CardContent>
            <div className="flex flex-wrap gap-2">
              {agent.capabilities.map((capability) => (
                <Badge
                  key={capability}
                  variant="outline"
                  className="border-gray-600 text-gray-300"
                >
                  {capability}
                </Badge>
              ))}
            </div>
          </CardContent>
        </Card>
      )}
    </div>
  );
}
