import { useQuery } from "@tanstack/react-query";
import { registrationApi } from "@/lib/api/registration";

/**
 * Whether the sign-in screen should offer account creation.
 *
 * Unauthenticated, so this runs on the login and register pages before any
 * session exists. It is a deployment-level setting, not per-user state — stale
 * time is generous, and while it is loading callers should render neither
 * answer rather than flash a link that is about to disappear.
 */
export function useRegistrationPolicy() {
  return useQuery({
    queryKey: ["registration-policy"],
    queryFn: () => registrationApi.policy(),
    staleTime: 5 * 60 * 1000,
    retry: false,
  });
}
