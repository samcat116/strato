"use client";

import type { ReactNode } from "react";
import { QueryProvider } from "./query-provider";
import { AuthProvider } from "./auth-provider";
import { OrganizationProvider } from "./organization-provider";
import { ProjectProvider } from "./project-provider";
import { Toaster } from "@/components/ui/sonner";

export function Providers({ children }: { children: ReactNode }) {
  return (
    <QueryProvider>
      <AuthProvider>
        <OrganizationProvider>
          <ProjectProvider>
            {children}
            <Toaster />
          </ProjectProvider>
        </OrganizationProvider>
      </AuthProvider>
    </QueryProvider>
  );
}

export { useAuth } from "./auth-provider";
export { useOrganization } from "./organization-provider";
export { useProjectContext } from "./project-provider";
