"use client";

import { Skeleton } from "@/components/ui/skeleton";
import { GroupsSection } from "@/components/organization-groups";
import { useCurrentOrgAccess } from "@/lib/hooks";

export default function GroupsPage() {
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
        <h2 className="text-2xl font-semibold text-foreground">Groups</h2>
        <p className="text-muted-foreground">
          Manage groups and the members that belong to them.
        </p>
      </div>
      <GroupsSection orgId={orgId} canManage={canManage} />
    </div>
  );
}
