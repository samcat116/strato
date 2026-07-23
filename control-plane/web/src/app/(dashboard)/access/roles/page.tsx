"use client";

import { Skeleton } from "@/components/ui/skeleton";
import { RolesSection } from "@/components/iam";
import { useCurrentOrgAccess } from "@/lib/hooks";

export default function RolesPage() {
  const { orgId, canManage, isLoading } = useCurrentOrgAccess();

  if (isLoading) {
    return (
      <div className="max-w-4xl mx-auto space-y-6">
        <Skeleton className="h-8 w-64 bg-muted" />
        <Skeleton className="h-64 w-full bg-muted" />
      </div>
    );
  }

  if (!orgId) {
    return (
      <div className="max-w-4xl mx-auto">
        <div className="text-center py-12">
          <p className="text-muted-foreground">No organization selected</p>
        </div>
      </div>
    );
  }

  return (
    <div className="max-w-4xl mx-auto space-y-6">
      <div>
        <h2 className="text-2xl font-semibold text-foreground">Roles</h2>
        <p className="text-muted-foreground">
          Define roles and the permissions they grant.
        </p>
      </div>
      <RolesSection ownerType="organization" ownerId={orgId} canManage={canManage} />
    </div>
  );
}
