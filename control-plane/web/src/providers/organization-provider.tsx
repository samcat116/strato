"use client";

import {
  createContext,
  useContext,
  useState,
  useCallback,
  useMemo,
  type ReactNode,
} from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { organizationsApi } from "@/lib/api/organizations";
import { useAuth } from "./auth-provider";
import type { Organization } from "@/types/api";

interface OrganizationContextType {
  currentOrg: Organization | null;
  organizations: Organization[];
  isLoading: boolean;
  switchOrg: (orgId: string) => Promise<void>;
  refresh: () => Promise<void>;
}

const OrganizationContext = createContext<OrganizationContextType | undefined>(
  undefined
);

export function OrganizationProvider({ children }: { children: ReactNode }) {
  const { user, isAuthenticated } = useAuth();
  const queryClient = useQueryClient();
  // Only track user-selected org; null means use default
  const [selectedOrgId, setSelectedOrgId] = useState<string | null>(null);

  const {
    data: organizations = [],
    isLoading,
    refetch,
  } = useQuery({
    queryKey: ["organizations"],
    queryFn: organizationsApi.list,
    enabled: isAuthenticated,
  });

  // Derive current org: user selection > user's default > first available
  const userCurrentOrgId = user?.currentOrganizationId;
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

  const switchOrg = useCallback(
    async (orgId: string) => {
      await organizationsApi.switch(orgId);
      setSelectedOrgId(orgId);
      // Invalidate queries that depend on current org
      queryClient.invalidateQueries({ queryKey: ["vms"] });
      queryClient.invalidateQueries({ queryKey: ["agents"] });
    },
    [queryClient]
  );

  const refresh = useCallback(async () => {
    await refetch();
  }, [refetch]);

  return (
    <OrganizationContext.Provider
      value={{
        currentOrg,
        organizations,
        isLoading,
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
