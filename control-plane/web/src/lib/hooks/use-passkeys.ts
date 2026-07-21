import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { passkeysApi } from "@/lib/api/passkeys";
import { ApiError } from "@/lib/api/client";
import { webAuthnClient } from "@/lib/webauthn";

export function usePasskeys() {
  return useQuery({
    queryKey: ["passkeys"],
    queryFn: () => passkeysApi.list(),
  });
}

export function useAddPasskey() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (name?: string) => webAuthnClient.addPasskey(name),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["passkeys"] });
    },
  });
}

export function useRenamePasskey() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: ({ id, name }: { id: string; name: string | null }) =>
      passkeysApi.rename(id, name),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["passkeys"] });
    },
  });
}

export function useDeletePasskey() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (id: string) => passkeysApi.delete(id),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["passkeys"] });
    },
  });
}

/**
 * User-facing message for a failed passkey operation. The browser's own
 * ceremony errors (cancelled prompt, authenticator already enrolled) surface as
 * DOMExceptions with unhelpful names, so they get plain-language equivalents.
 */
export function passkeyErrorMessage(error: unknown, fallback: string): string {
  if (error instanceof ApiError) {
    return error.message || fallback;
  }
  if (error instanceof DOMException) {
    switch (error.name) {
      case "NotAllowedError":
        return "Passkey setup was cancelled or timed out.";
      case "InvalidStateError":
        return "This device already has a passkey for your account.";
      case "SecurityError":
        return "This site's origin doesn't match the passkey configuration.";
      default:
        return error.message || fallback;
    }
  }
  return error instanceof Error ? error.message : fallback;
}
