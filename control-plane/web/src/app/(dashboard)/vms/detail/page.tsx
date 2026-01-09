"use client";

import { useSearchParams } from "next/navigation";
import Link from "next/link";
import { ArrowLeft, Cpu, HardDrive, MemoryStick, Clock } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { VMStatusBadge, VMActions } from "@/components/vms";
import { useVM, useInvalidateVMs } from "@/lib/hooks";

export default function VMDetailPage() {
  const searchParams = useSearchParams();
  const id = searchParams.get("id") || "";
  const { data: vm, isLoading, error } = useVM(id);
  const invalidateVMs = useInvalidateVMs();

  if (!id) {
    return (
      <div className="max-w-4xl mx-auto">
        <div className="text-center py-12">
          <p className="text-gray-400 mb-4">No VM ID provided</p>
          <Link href="/vms">
            <Button variant="outline" className="border-gray-600">
              <ArrowLeft className="h-4 w-4 mr-2" />
              Back to VMs
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

  if (error || !vm) {
    return (
      <div className="max-w-4xl mx-auto">
        <div className="text-center py-12">
          <p className="text-gray-400 mb-4">VM not found or failed to load</p>
          <Link href="/vms">
            <Button variant="outline" className="border-gray-600">
              <ArrowLeft className="h-4 w-4 mr-2" />
              Back to VMs
            </Button>
          </Link>
        </div>
      </div>
    );
  }

  return (
    <div className="max-w-4xl mx-auto space-y-6">
      {/* Header */}
      <div className="flex items-start justify-between">
        <div>
          <Link
            href="/vms"
            className="text-sm text-gray-400 hover:text-gray-200 flex items-center mb-2"
          >
            <ArrowLeft className="h-4 w-4 mr-1" />
            Back to VMs
          </Link>
          <div className="flex items-center gap-3">
            <h2 className="text-2xl font-semibold text-gray-100">{vm.name}</h2>
            <VMStatusBadge status={vm.status} />
          </div>
          {vm.description && (
            <p className="text-gray-400 mt-1">{vm.description}</p>
          )}
        </div>
        <VMActions vm={vm} onActionComplete={invalidateVMs} />
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
              {vm.cpu} / {vm.maxCpu}
            </div>
            <p className="text-sm text-gray-500">cores</p>
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
            <div className="text-xl font-bold text-gray-100">{vm.memory}</div>
            <p className="text-sm text-gray-500">GB</p>
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
            <div className="text-xl font-bold text-gray-100">{vm.disk}</div>
            <p className="text-sm text-gray-500">GB</p>
          </CardContent>
        </Card>
        <Card className="bg-gray-800 border-gray-700">
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium text-gray-400 flex items-center gap-2">
              <Clock className="h-4 w-4" />
              Created
            </CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-sm font-medium text-gray-100">
              {new Date(vm.createdAt).toLocaleDateString()}
            </div>
            <p className="text-sm text-gray-500">
              {new Date(vm.createdAt).toLocaleTimeString()}
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
              <p className="text-gray-100 font-mono">{vm.id}</p>
            </div>
            <div>
              <p className="text-gray-400">Image</p>
              <p className="text-gray-100">{vm.image}</p>
            </div>
            <div>
              <p className="text-gray-400">Hypervisor</p>
              <p className="text-gray-100">{vm.hypervisorId || "Unassigned"}</p>
            </div>
            <div>
              <p className="text-gray-400">Last Updated</p>
              <p className="text-gray-100">
                {new Date(vm.updatedAt).toLocaleString()}
              </p>
            </div>
          </div>
        </CardContent>
      </Card>
    </div>
  );
}
