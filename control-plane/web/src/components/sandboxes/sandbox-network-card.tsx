"use client";

import Link from "next/link";
import { AlertTriangle } from "lucide-react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import {
  NicSecurityGroupMenu,
  NicSecurityGroupNames,
} from "@/components/security-groups/nic-security-groups";
import { useSecurityGroups } from "@/lib/hooks/use-security-groups";
import { type Sandbox, type SandboxNetworkInterface } from "@/types/api";

/** All addresses of a NIC as `address/prefix`. */
function nicAddresses(nic: SandboxNetworkInterface): string[] {
  return (nic.addresses ?? []).map((a) => `${a.address}/${a.prefixLength}`);
}

function nicGateways(nic: SandboxNetworkInterface): string[] {
  return (nic.addresses ?? []).flatMap((a) => (a.gateway ? [a.gateway] : []));
}

/**
 * A sandbox's NIC and its security groups (backend STR-102) — the sandbox
 * counterpart of {@link VMNetworkCard}, sharing its attach/detach menu. No
 * "observed (guest)" column: sandboxes run no guest agent.
 */
export function SandboxNetworkCard({ sandbox }: { sandbox: Sandbox }) {
  const interfaces = sandbox.networkInterfaces ?? [];
  const { data: securityGroups = [], isError: securityGroupsFailed } =
    useSecurityGroups(sandbox.projectId);
  const showSecurityGroups = securityGroups.length > 0;

  return (
    <Card className="bg-card border-border">
      <CardHeader>
        <CardTitle className="text-lg font-semibold text-foreground">
          Network Interface
        </CardTitle>
      </CardHeader>
      <CardContent>
        {sandbox.securityGroupsEnforced === false && (
          // Same reason as the VM banner — showing groups that filter nothing
          // reads as "filtered" — but a different cause, so different copy:
          // nothing is wrong with the host here, sandbox guest networking is
          // simply not switched on yet.
          <div className="mb-3 flex items-start gap-2 rounded-md border border-amber-500/40 bg-amber-500/10 p-3 text-sm text-amber-700 dark:text-amber-400">
            <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" />
            <span>
              Security groups are <strong>not enforced</strong> on sandboxes
              yet: guest networking is not enabled, so this interface is an
              address reservation and the groups below filter nothing. The
              memberships are recorded and will take effect as soon as it is.
            </span>
          </div>
        )}
        {interfaces.length === 0 ? (
          <div className="text-center py-6 text-muted-foreground">
            No network interface. A sandbox only gets one if a network was
            chosen when it was created.
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
                {showSecurityGroups && (
                  <>
                    <TableHead className="text-muted-foreground font-medium">
                      Security groups
                    </TableHead>
                    <TableHead className="text-muted-foreground font-medium text-right">
                      Actions
                    </TableHead>
                  </>
                )}
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
                  <TableCell className="text-foreground/80">
                    {nic.network ?? nic.networkId}
                  </TableCell>
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
                  {showSecurityGroups && (
                    <>
                      <TableCell>
                        <NicSecurityGroupNames
                          nic={nic}
                          groups={securityGroups}
                        />
                      </TableCell>
                      <TableCell className="text-right">
                        {nic.id ? (
                          <NicSecurityGroupMenu
                            target={{ sandboxId: sandbox.id }}
                            nic={nic}
                            groups={securityGroups}
                          />
                        ) : null}
                      </TableCell>
                    </>
                  )}
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
        {showSecurityGroups && interfaces.length > 0 && (
          <p className="mt-3 text-xs text-muted-foreground">
            Every interface belongs to at least one security group. Rules are
            managed on the{" "}
            <Link
              href="/security-groups"
              className="text-blue-600 hover:underline"
            >
              Security Groups
            </Link>{" "}
            page.
          </p>
        )}
        {securityGroupsFailed && (
          // A failed fetch must not silently hide the security-group UI as if
          // no groups existed.
          <p className="mt-3 text-xs text-red-600">
            Failed to load security groups; attach/detach is unavailable until
            the page is refreshed.
          </p>
        )}
      </CardContent>
    </Card>
  );
}
