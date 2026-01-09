"use client";

import Link from "next/link";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { Skeleton } from "@/components/ui/skeleton";
import { VMStatusBadge } from "./vm-status-badge";
import { VMActions } from "./vm-actions";
import type { VM } from "@/types/api";

interface VMTableProps {
  vms: VM[];
  isLoading?: boolean;
  onRefresh?: () => void;
}

export function VMTable({ vms, isLoading, onRefresh }: VMTableProps) {
  if (isLoading) {
    return (
      <div className="space-y-2">
        {[...Array(3)].map((_, i) => (
          <Skeleton key={i} className="h-12 w-full bg-gray-700" />
        ))}
      </div>
    );
  }

  if (vms.length === 0) {
    return (
      <div className="text-center py-8 text-gray-400">
        No virtual machines found. Create one to get started.
      </div>
    );
  }

  return (
    <Table>
      <TableHeader className="bg-gray-900">
        <TableRow className="border-gray-700 hover:bg-gray-900">
          <TableHead className="text-gray-400 font-medium">Name</TableHead>
          <TableHead className="text-gray-400 font-medium">Status</TableHead>
          <TableHead className="text-gray-400 font-medium">CPU</TableHead>
          <TableHead className="text-gray-400 font-medium">Memory</TableHead>
          <TableHead className="text-gray-400 font-medium">Disk</TableHead>
          <TableHead className="text-gray-400 font-medium text-right">
            Actions
          </TableHead>
        </TableRow>
      </TableHeader>
      <TableBody className="divide-y divide-gray-700">
        {vms.map((vm) => (
          <TableRow
            key={vm.id}
            className="border-gray-700 hover:bg-gray-800/50 cursor-pointer"
          >
            <TableCell>
              <Link
                href={`/vms/detail?id=${vm.id}`}
                className="font-medium text-gray-100 hover:text-blue-400"
              >
                {vm.name}
              </Link>
              {vm.description && (
                <p className="text-sm text-gray-500 truncate max-w-xs">
                  {vm.description}
                </p>
              )}
            </TableCell>
            <TableCell>
              <VMStatusBadge status={vm.status} />
            </TableCell>
            <TableCell className="text-gray-300">
              {vm.cpu} / {vm.maxCpu} cores
            </TableCell>
            <TableCell className="text-gray-300">{vm.memory} GB</TableCell>
            <TableCell className="text-gray-300">{vm.disk} GB</TableCell>
            <TableCell className="text-right">
              <VMActions vm={vm} onActionComplete={onRefresh} />
            </TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  );
}
