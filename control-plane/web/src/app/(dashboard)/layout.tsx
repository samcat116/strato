"use client";

import { useEffect } from "react";
import { useRouter } from "next/navigation";
import { Header, Sidebar } from "@/components/layout";
import { Button } from "@/components/ui/button";
import { MutationWatcher } from "@/components/vms";
import { useAuth, useOrganization } from "@/providers";

export default function DashboardLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const { isAuthenticated, isLoading, sessionError, refresh } = useAuth();
  const { organizations, isLoading: orgsLoading } = useOrganization();
  const router = useRouter();

  useEffect(() => {
    if (!isLoading && !isAuthenticated && !sessionError) {
      router.replace("/login");
    }
  }, [isAuthenticated, isLoading, router, sessionError]);

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

  if (sessionError && !isAuthenticated) {
    return (
      <div className="min-h-screen flex flex-col items-center justify-center gap-4 p-6 text-center">
        <div>
          <h1 className="text-xl font-semibold">Unable to verify your session</h1>
          <p className="mt-2 text-sm text-muted-foreground">
            The control plane may be temporarily unavailable. You have not been signed out.
          </p>
        </div>
        <Button onClick={() => void refresh()}>Try again</Button>
      </div>
    );
  }

  if (!isAuthenticated || needsOnboarding) {
    return null;
  }

  return (
    <div className="flex h-screen overflow-hidden">
      <a
        href="#main-content"
        className="sr-only z-50 rounded-md bg-background px-4 py-2 focus:not-sr-only focus:fixed focus:left-4 focus:top-4"
      >
        Skip to main content
      </a>
      {/* Follows in-flight mutations to completion across page navigations */}
      <MutationWatcher />
      <Sidebar className="hidden lg:flex" />
      <div className="flex min-w-0 flex-1 flex-col">
        <Header />
        <main id="main-content" className="flex-1 overflow-y-auto p-4 sm:p-6">
          {children}
        </main>
      </div>
    </div>
  );
}
