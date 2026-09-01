// Registration policy for the sign-in screen.
//
// Public, like the SSO lookup next to it: the login and register pages call it
// before any session exists. The backend answers with the *effective* policy
// (bootstrap already folded in), so callers just render on
// `selfRegistrationEnabled`.
import { api } from "./client";
import type { RegistrationPolicy } from "@/types/api-contracts";

export const registrationApi = {
  policy(signal?: AbortSignal): Promise<RegistrationPolicy> {
    return api.get<RegistrationPolicy>("/api/public/registration", undefined, signal);
  },
};
