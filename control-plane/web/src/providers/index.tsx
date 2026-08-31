"use client";

import type { ReactNode } from "react";
import { ThemeProvider } from "next-themes";
import { QueryProvider } from "./query-provider";
import { AuthProvider } from "./auth-provider";
import { OrganizationProvider } from "./organization-provider";
import { ProjectProvider } from "./project-provider";
import { Toaster } from "@/components/ui/sonner";
import type { FrontendBootstrap } from "@/lib/bootstrap-data";
import { ConfirmationProvider } from "./confirmation-provider";

export function Providers({
  bootstrap,
  children,
}: {
  bootstrap: FrontendBootstrap;
  children: ReactNode;
}) {
  return (
    <ThemeProvider attribute="class" defaultTheme="system" enableSystem disableTransitionOnChange>
      <QueryProvider>
        <AuthProvider
          initialUser={bootstrap.user}
          initialError={bootstrap.sessionError}
          refreshOnMount={bootstrap.source === "client"}
        >
          <OrganizationProvider
            initialOrganizations={
              bootstrap.user ? bootstrap.organizations ?? undefined : undefined
            }
          >
            <ProjectProvider
              initialProjects={
                bootstrap.user ? bootstrap.projects ?? undefined : undefined
              }
              initialOrganizationId={
                bootstrap.user ? bootstrap.projectOrganizationId : null
              }
            >
              <ConfirmationProvider>
                {children}
                <Toaster />
              </ConfirmationProvider>
            </ProjectProvider>
          </OrganizationProvider>
        </AuthProvider>
      </QueryProvider>
    </ThemeProvider>
  );
}

export { useAuth } from "./auth-provider";
export { useOrganization } from "./organization-provider";
export { useProjectContext, NO_PROJECT_DESCRIPTION } from "./project-provider";
