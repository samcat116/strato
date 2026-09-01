"use client";

import {
  createContext,
  useContext,
  useState,
  useCallback,
  useMemo,
  type ReactNode,
} from "react";
import { useQuery } from "@tanstack/react-query";
import { organizationsApi } from "@/lib/api/organizations";
import { useAuth } from "./auth-provider";
import type { Organization } from "@/types/api";

interface OrganizationContextType {
  currentOrg: Organization | null;
  organizations: Organization[];
  isLoading: boolean;
  error: unknown;
  switchOrg: (orgId: string) => Promise<void>;
  refresh: () => Promise<void>;
}

const OrganizationContext = createContext<OrganizationContextType | undefined>(
  undefined
);

export function OrganizationProvider({
  children,
  initialOrganizations,
}: {
  children: ReactNode;
  initialOrganizations?: Organization[];
}) {
  const { user, isAuthenticated } = useAuth();
  const userId = user?.id;
  // Only track user-selected org; null means use default
  const [selection, setSelection] = useState<{
    userId: string;
    orgId: string;
  } | null>(null);

  const {
    data: organizations = [],
    isLoading,
    error,
    refetch,
  } = useQuery({
    queryKey: ["organizations", { userId }],
    queryFn: ({ signal }) => organizationsApi.list(signal),
    enabled: isAuthenticated,
    initialData: isAuthenticated ? initialOrganizations : undefined,
  });

  // Derive current org: user selection > user's default > first available
  const userCurrentOrgId = user?.currentOrganizationId;
  const selectedOrgId =
    selection && selection.userId === userId ? selection.orgId : null;
  const currentOrg = useMemo(() => {
    if (selectedOrgId) {
      const selected = organizations.find((o) => o.id === selectedOrgId);
      if (selected) return selected;
    }
    if (userCurrentOrgId) {
      const userDefault = organizations.find((o) => o.id === userCurrentOrgId);
      if (userDefault) return userDefault;
    }
    return organizations[0] || null;
  }, [selectedOrgId, organizations, userCurrentOrgId]);

  const switchOrg = useCallback(async (orgId: string) => {
    await organizationsApi.switch(orgId);
    if (userId) setSelection({ userId, orgId });
    // No invalidation needed: org-scoped queries carry the org id in their key,
    // so changing it refetches them. A hand-maintained list here only drifts —
    // it used to cover vms and agents while sites and sandboxes went stale.
  }, [userId]);

  const refresh = useCallback(async () => {
    await refetch();
  }, [refetch]);

  return (
    <OrganizationContext.Provider
      value={{
        currentOrg,
        organizations,
        isLoading,
        error,
        switchOrg,
        refresh,
      }}
    >
      {children}
    </OrganizationContext.Provider>
  );
}

export function useOrganization() {
  const context = useContext(OrganizationContext);
  if (!context) {
    throw new Error(
      "useOrganization must be used within OrganizationProvider"
    );
  }
  return context;
}
