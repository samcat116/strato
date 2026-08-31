import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { Network, NetworkACL } from "@/types/api";
import { NetworkACLDialog } from "./network-acl-dialog";
import { NetworkTable } from "./network-table";

const state = vi.hoisted(() => ({
  permissions: {} as Record<string, boolean>,
  acl: null as NetworkACL | null,
}));

vi.mock("@/lib/hooks/use-permissions", () => ({
  usePermissions: () => ({ permissions: state.permissions, isLoading: false }),
}));

vi.mock("@/lib/hooks/use-networks", () => ({
  useNetworkACL: () => ({
    data: state.acl,
    isLoading: false,
    isError: false,
    error: null,
    refetch: vi.fn(),
  }),
  useCreateNetworkACL: () => ({ isPending: false, mutateAsync: vi.fn() }),
  useDeleteNetworkACL: () => ({ isPending: false, mutateAsync: vi.fn() }),
  useCreateNetworkACLRule: () => ({ isPending: false, mutateAsync: vi.fn() }),
  useDeleteNetworkACLRule: () => ({ isPending: false, mutateAsync: vi.fn() }),
}));

const network: Network = {
  id: "network-1",
  name: "private",
  subnet: "10.0.0.0/24",
  projectId: "project-1",
  attachedInterfaceCount: 1,
  dhcpEnabled: true,
  dnsServers: [],
  metadataEnabled: true,
  resolverEnabled: true,
};

describe("network ACL permissions", () => {
  afterEach(cleanup);

  beforeEach(() => {
    state.permissions = {
      "read:network-1": true,
      "update:network-1": false,
      "delete:network-1": false,
    };
    state.acl = {
      id: "acl-1",
      networkId: "network-1",
      generation: 2,
      rules: [
        {
          id: "rule-1",
          ruleNumber: 100,
          direction: "ingress",
          ethertype: "ipv4",
          action: "allow",
          protocolName: "tcp",
          portRangeMin: 443,
          portRangeMax: 443,
          remoteCIDR: "10.20.0.0/16",
        },
      ],
    };
  });

  it("opens ACL inspection for a network reader without granting management", () => {
    const onManageACL = vi.fn();
    render(<NetworkTable networks={[network]} onManageACL={onManageACL} />);

    fireEvent.click(screen.getByRole("button", { name: "View ACL for private" }));

    expect(onManageACL).toHaveBeenCalledWith(network, false);
    expect(screen.queryByRole("button", { name: "Edit private" })).toBeNull();
  });

  it("preserves the management entry point for a network updater", () => {
    state.permissions = {
      "read:network-1": true,
      "update:network-1": true,
      "delete:network-1": false,
    };
    const onManageACL = vi.fn();
    render(<NetworkTable networks={[network]} onManageACL={onManageACL} />);

    fireEvent.click(
      screen.getByRole("button", { name: "Manage ACL for private" })
    );

    expect(onManageACL).toHaveBeenCalledWith(network, true);
  });

  it("shows policy but no mutations in a read-only ACL dialog", () => {
    render(
      <NetworkACLDialog
        network={network}
        canManage={false}
        open
        onOpenChange={vi.fn()}
      />
    );

    expect(screen.getByText("#100")).toBeInTheDocument();
    expect(
      screen.getByText("Read-only access: rule and ACL mutations are unavailable.")
    ).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Add Rule" })).toBeNull();
    expect(screen.queryByRole("button", { name: "Delete ACL" })).toBeNull();
    expect(
      screen.queryByRole("button", { name: "Delete ingress rule 100" })
    ).toBeNull();
  });

  it("does not offer ACL creation to a read-only user", () => {
    state.acl = null;
    render(
      <NetworkACLDialog
        network={network}
        canManage={false}
        open
        onOpenChange={vi.fn()}
      />
    );

    expect(screen.queryByRole("button", { name: "Create Empty ACL" })).toBeNull();
    expect(screen.getByText(/Read-only access: you can inspect/)).toBeInTheDocument();
  });
});
