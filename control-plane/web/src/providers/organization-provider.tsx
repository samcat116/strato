"use client";

import {
  createContext,
  useContext,
  useState,
  useCallback,
  useEffect,
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
  const [currentOrgId, setCurrentOrgId] = useState<string | null>(null);

  const {
    data: organizations = [],
    isLoading,
    refetch,
  } = useQuery({
    queryKey: ["organizations"],
    queryFn: organizationsApi.list,
    enabled: isAuthenticated,
  });

  // Set initial org from user's current org or first org
  useEffect(() => {
    if (!currentOrgId && organizations.length > 0) {
      const initialOrg = user?.currentOrganizationId
        ? organizations.find((o) => o.id === user.currentOrganizationId)
        : organizations[0];
      if (initialOrg) {
        setCurrentOrgId(initialOrg.id);
      }
    }
  }, [organizations, user?.currentOrganizationId, currentOrgId]);

  const currentOrg =
    organizations.find((o) => o.id === currentOrgId) ||
    organizations[0] ||
    null;

  const switchOrg = useCallback(
    async (orgId: string) => {
      await organizationsApi.switch(orgId);
      setCurrentOrgId(orgId);
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
