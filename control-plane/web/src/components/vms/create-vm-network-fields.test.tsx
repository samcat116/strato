import { cleanup, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { SecurityGroup } from "@/types/api";
import { initialNIC, VMNetworkInterfacesFields } from "./create-vm-network-fields";

describe("VM creation networking capabilities", () => {
  afterEach(cleanup);
  const group = { id: "group-1", name: "Web" } as SecurityGroup;
  function show(nativeNAT: boolean) {
    render(<VMNetworkInterfacesFields isLoading={false} networkInterfaces={[initialNIC()]}
      setNetworkInterfaces={vi.fn()} networks={[]} securityGroups={[group]}
      securityGroupsFailed={false} nativeNAT={nativeNAT} />);
  }

  it("explains native NAT and omits security groups that cannot be enforced", () => {
    show(true);
    expect(screen.queryByRole("checkbox")).not.toBeInTheDocument();
    expect(screen.getByText(/managed IP addresses, DNS registration, and security groups are unavailable/)).toBeInTheDocument();
    expect(screen.queryByText(/Default group is used/)).not.toBeInTheDocument();
  });

  it("keeps managed networking security-group selection available", () => {
    show(false);
    expect(screen.getByRole("checkbox", { name: "Web" })).toBeEnabled();
    expect(screen.getByText(/Default group is used/)).toBeInTheDocument();
  });
});
