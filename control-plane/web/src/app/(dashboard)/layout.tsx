"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { Header, Sidebar } from "@/components/layout";
import { CreateVMDialog, OperationWatcher } from "@/components/vms";
import { CreateTokenDialog } from "@/components/agents";
import { useAuth, useOrganization } from "@/providers";
import { useInvalidateVMs } from "@/lib/hooks";

export default function DashboardLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const { isAuthenticated, isLoading } = useAuth();
  const { organizations, isLoading: orgsLoading } = useOrganization();
  const router = useRouter();
  const [createVMOpen, setCreateVMOpen] = useState(false);
  const [addAgentOpen, setAddAgentOpen] = useState(false);
  const invalidateVMs = useInvalidateVMs();

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
        <div className="text-gray-400">Loading...</div>
      </div>
    );
  }

  if (!isAuthenticated || needsOnboarding) {
    return null;
  }

  return (
    <div className="min-h-screen flex flex-col">
      {/* Polls in-flight VM operations to completion across page navigations */}
      <OperationWatcher />
      <Header />
      <div className="flex flex-1 h-[calc(100vh-4rem)]">
        <Sidebar
          onCreateVM={() => setCreateVMOpen(true)}
          onAddAgent={() => setAddAgentOpen(true)}
        />
        <main className="flex-1 overflow-y-auto p-6">{children}</main>
      </div>

      {/* Global dialogs accessible from sidebar */}
      <CreateVMDialog
        open={createVMOpen}
        onOpenChange={setCreateVMOpen}
        onCreated={invalidateVMs}
      />
      <CreateTokenDialog
        open={addAgentOpen}
        onOpenChange={setAddAgentOpen}
      />
    </div>
  );
}
