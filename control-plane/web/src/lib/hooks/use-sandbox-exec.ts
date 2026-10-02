import { useGuestExec, type UseGuestExecOptions } from "./use-guest-exec";

export function useSandboxExec({ sandboxId, ...options }: Omit<UseGuestExecOptions, "resourceId" | "resourceKind"> & { sandboxId: string }) {
  return useGuestExec({ ...options, resourceId: sandboxId, resourceKind: "sandbox" });
}
