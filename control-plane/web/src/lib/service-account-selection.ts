import type { ServiceAccount } from "@/lib/api/platform-services";

export function selectedServiceAccountForProject(
  accounts: ServiceAccount[] | undefined,
  selectedAccountId: string,
  projectId: string | undefined
): ServiceAccount | undefined {
  if (!selectedAccountId || !projectId) return undefined;

  return accounts?.find(
    (account) =>
      account.id === selectedAccountId && account.projectId === projectId
  );
}
