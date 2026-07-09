"use client";

import { useEffect } from "react";
import { useRouter } from "next/navigation";
import { Header, Sidebar } from "@/components/layout";
import { OperationWatcher } from "@/components/vms";
import { useAuth, useOrganization } from "@/providers";

export default function DashboardLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const { isAuthenticated, isLoading } = useAuth();
  const { organizations, isLoading: orgsLoading } = useOrganization();
  const router = useRouter();

  useEffect(() => {
    if (!isLoading && !isAuthenticated) {
      router.replace("/login");
    }
  }, [isAuthenticated, isLoading, router]);

  // First-run onboarding: an authenticated user with no organization (the
  // first system admin) is sent to create their initial org before the
  // dashboard, which has nothing to show without one.
  const needsOnboarding =
    isAuthenticated && !orgsLoading && organizations.length === 0;

  useEffect(() => {
    if (needsOnboarding) {
      router.replace("/onboarding");
    }
  }, [needsOnboarding, router]);

  // Hold the loading state until we know both auth and org membership, so we
  // never flash the empty dashboard before redirecting to onboarding.
  if (isLoading || (isAuthenticated && orgsLoading)) {
    return (
      <div className="min-h-screen flex items-center justify-center">
        <div className="text-muted-foreground">Loading...</div>
      </div>
    );
  }

  if (!isAuthenticated || needsOnboarding) {
    return null;
  }

  return (
    <div className="flex h-screen overflow-hidden">
      {/* Polls in-flight VM operations to completion across page navigations */}
      <OperationWatcher />
      <Sidebar />
      <div className="flex min-w-0 flex-1 flex-col">
        <Header />
        <main className="flex-1 overflow-y-auto p-6">{children}</main>
      </div>
    </div>
  );
}
