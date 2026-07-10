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
import type { VM, VMNetworkInterface } from "@/types/api";

/** All addresses of a NIC as `address/prefix`. */
function nicAddresses(nic: VMNetworkInterface): string[] {
  return (nic.addresses ?? []).map((a) => `${a.address}/${a.prefixLength}`);
}

function nicGateways(nic: VMNetworkInterface): string[] {
  return (nic.addresses ?? []).flatMap((a) => (a.gateway ? [a.gateway] : []));
}

export function VMNetworkCard({ vm }: { vm: VM }) {
  const interfaces = vm.networkInterfaces ?? [];

  return (
    <Card className="bg-card border-border">
      <CardHeader>
        <CardTitle className="text-lg font-semibold text-foreground">
          Network Interfaces
        </CardTitle>
      </CardHeader>
      <CardContent>
        {interfaces.length === 0 ? (
          <div className="text-center py-6 text-muted-foreground">
            No network interfaces.
          </div>
        ) : (
          <Table>
            <TableHeader className="bg-background">
              <TableRow className="border-border hover:bg-transparent">
                <TableHead className="text-muted-foreground font-medium">
                  Device
                </TableHead>
                <TableHead className="text-muted-foreground font-medium">
                  Network
                </TableHead>
                <TableHead className="text-muted-foreground font-medium">
                  MAC
                </TableHead>
                <TableHead className="text-muted-foreground font-medium">
                  Addresses
                </TableHead>
                <TableHead className="text-muted-foreground font-medium">
                  Gateway
                </TableHead>
                <TableHead className="text-muted-foreground font-medium">
                  MTU
                </TableHead>
              </TableRow>
            </TableHeader>
            <TableBody className="divide-y divide-border">
              {interfaces.map((nic) => (
                <TableRow
                  key={nic.id ?? nic.deviceName}
                  className="border-border hover:bg-accent/60"
                >
                  <TableCell className="text-foreground/80 font-mono text-sm">
                    {nic.deviceName}
                  </TableCell>
                  <TableCell className="text-foreground/80">{nic.network}</TableCell>
                  <TableCell className="text-foreground/80 font-mono text-sm">
                    {nic.macAddress}
                  </TableCell>
                  <TableCell className="text-foreground/80 font-mono text-sm">
                    {nicAddresses(nic).length > 0
                      ? nicAddresses(nic).map((address) => (
                          <div key={address}>{address}</div>
                        ))
                      : "—"}
                  </TableCell>
                  <TableCell className="text-foreground/80 font-mono text-sm">
                    {nicGateways(nic).length > 0
                      ? nicGateways(nic).map((gateway) => (
                          <div key={gateway}>{gateway}</div>
                        ))
                      : "—"}
                  </TableCell>
                  <TableCell className="text-foreground/80">
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
