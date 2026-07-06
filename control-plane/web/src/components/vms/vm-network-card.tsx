"use client";

import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import type { VM } from "@/types/api";

export function VMNetworkCard({ vm }: { vm: VM }) {
  const interfaces = vm.networkInterfaces ?? [];

  return (
    <Card className="bg-gray-800 border-gray-700">
      <CardHeader>
        <CardTitle className="text-lg font-semibold text-gray-100">
          Network Interfaces
        </CardTitle>
      </CardHeader>
      <CardContent>
        {interfaces.length === 0 ? (
          <div className="text-center py-6 text-gray-400">
            No network interfaces.
          </div>
        ) : (
          <Table>
            <TableHeader className="bg-gray-900">
              <TableRow className="border-gray-700 hover:bg-gray-900">
                <TableHead className="text-gray-400 font-medium">
                  Device
                </TableHead>
                <TableHead className="text-gray-400 font-medium">
                  Network
                </TableHead>
                <TableHead className="text-gray-400 font-medium">
                  MAC
                </TableHead>
                <TableHead className="text-gray-400 font-medium">
                  IP Address
                </TableHead>
                <TableHead className="text-gray-400 font-medium">
                  Netmask
                </TableHead>
                <TableHead className="text-gray-400 font-medium">
                  Gateway
                </TableHead>
                <TableHead className="text-gray-400 font-medium">
                  MTU
                </TableHead>
              </TableRow>
            </TableHeader>
            <TableBody className="divide-y divide-gray-700">
              {interfaces.map((nic) => (
                <TableRow
                  key={nic.id ?? nic.deviceName}
                  className="border-gray-700 hover:bg-gray-800/50"
                >
                  <TableCell className="text-gray-300 font-mono text-sm">
                    {nic.deviceName}
                  </TableCell>
                  <TableCell className="text-gray-300">{nic.network}</TableCell>
                  <TableCell className="text-gray-300 font-mono text-sm">
                    {nic.macAddress}
                  </TableCell>
                  <TableCell className="text-gray-300 font-mono text-sm">
                    {nic.ipAddress ?? "—"}
                  </TableCell>
                  <TableCell className="text-gray-300 font-mono text-sm">
                    {nic.netmask ?? "—"}
                  </TableCell>
                  <TableCell className="text-gray-300 font-mono text-sm">
                    {nic.gateway ?? "—"}
                  </TableCell>
                  <TableCell className="text-gray-300">
                    {nic.mtu ?? "—"}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
      </CardContent>
    </Card>
  );
}
