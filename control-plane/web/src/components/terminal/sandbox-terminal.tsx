"use client";

import { GuestTerminal, type GuestTerminalProps } from "./guest-terminal";

export function SandboxTerminal({ sandboxId, ...props }: Omit<GuestTerminalProps, "resourceId" | "resourceKind"> & { sandboxId: string }) {
  return <GuestTerminal {...props} resourceId={sandboxId} resourceKind="sandbox" />;
}
