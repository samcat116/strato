"use client";

import { ShieldAlert } from "lucide-react";
import { Skeleton } from "@/components/ui/skeleton";
import { WorkloadIdentityView } from "@/components/workload-identity";
import {
  useWorkloadIdentity,
  workloadIdentityErrorMessage,
} from "@/lib/hooks/use-workload-identity";
import { useAuth } from "@/providers";

export default function WorkloadIdentityPage() {
  const { user, isLoading: isAuthLoading } = useAuth();
  const isSystemAdmin = !!user?.isSystemAdmin;
  const { data, isLoading, error } = useWorkloadIdentity(isSystemAdmin);

  if (isAuthLoading) {
    return (
      <div className="max-w-7xl mx-auto space-y-6">
        <Skeleton className="h-8 w-64 bg-muted" />
        <Skeleton className="h-96 w-full bg-muted" />
      </div>
    );
  }

  if (!isSystemAdmin) {
    return (
      <div className="max-w-7xl mx-auto">
        <div className="text-center py-12">
          <ShieldAlert className="h-10 w-10 mx-auto mb-4 text-muted-foreground" />
          <p className="text-muted-foreground">
            You need system administrator rights to view workload identity.
          </p>
        </div>
      </div>
    );
  }

  return (
    <WorkloadIdentityView
      data={data}
      isLoading={isLoading}
      errorMessage={
        error
          ? workloadIdentityErrorMessage(error, "Failed to load workload identity data")
          : undefined
      }
    />
  );
}
