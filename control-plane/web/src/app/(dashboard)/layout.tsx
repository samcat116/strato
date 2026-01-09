"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { Header, Sidebar } from "@/components/layout";
import { CreateVMDialog } from "@/components/vms";
import { CreateTokenDialog } from "@/components/agents";
import { useAuth } from "@/providers";
import { useInvalidateVMs } from "@/lib/hooks";

export default function DashboardLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const { isAuthenticated, isLoading } = useAuth();
  const router = useRouter();
  const [createVMOpen, setCreateVMOpen] = useState(false);
  const [addAgentOpen, setAddAgentOpen] = useState(false);
  const invalidateVMs = useInvalidateVMs();

  useEffect(() => {
    if (!isLoading && !isAuthenticated) {
      router.replace("/login");
    }
  }, [isAuthenticated, isLoading, router]);

  if (isLoading) {
    return (
      <div className="min-h-screen flex items-center justify-center">
        <div className="text-gray-400">Loading...</div>
      </div>
    );
  }

  if (!isAuthenticated) {
    return null;
  }

  return (
    <div className="min-h-screen flex flex-col">
      <Header />
      <div className="flex flex-1 h-[calc(100vh-4rem)]">
        <Sidebar
          onCreateVM={() => setCreateVMOpen(true)}
          onAddAgent={() => setAddAgentOpen(true)}
          onManageAPIKeys={() => {
            // TODO: Implement API keys management dialog
            router.push("/organizations/settings");
          }}
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
