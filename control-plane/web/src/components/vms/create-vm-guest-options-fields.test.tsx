import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { VMGuestOptionsFields } from "./create-vm-guest-options-fields";

function fields(isFirecracker = false) {
  const setGuestAgentEnabled = vi.fn();
  render(<VMGuestOptionsFields
    isLoading={false} isFirecracker={isFirecracker}
    metadataEnabled metadataSource="iso" metadataSourceForcedToISO={false}
    allSelectedNetworksDisableMetadata={false} secureBoot={false} tpm={false}
    graphicsConsole={false} guestAgentEnabled={false}
    setMetadataEnabled={vi.fn()} setMetadataSource={vi.fn()}
    setSecureBoot={vi.fn()} setTpm={vi.fn()} setGraphicsConsole={vi.fn()}
    setGuestAgentEnabled={setGuestAgentEnabled}
    userData={"#!/bin/sh\necho tenant"} onUserDataChange={vi.fn()}
  />);
  return setGuestAgentEnabled;
}
describe("Guest-agent opt-in", () => {
  afterEach(cleanup);
  it("starts off, discloses root execution and recreation, and allows explicit opt-in", () => {
    const change = fields();
    const option = screen.getByRole("checkbox", { name: /Install Strato guest agent/ });
    expect(option).not.toBeChecked();
    expect(screen.getByText(/Recreation is required/)).toBeInTheDocument();
    fireEvent.click(option);
    expect(change).toHaveBeenCalledWith(true);
    expect(screen.getByLabelText(/Cloud-init user data/)).toHaveValue("#!/bin/sh\necho tenant");
  });
  it("does not offer installation for Firecracker", () => {
    fields(true);
    expect(screen.getByRole("checkbox", { name: /Install Strato guest agent/ })).toBeDisabled();
  });
});
