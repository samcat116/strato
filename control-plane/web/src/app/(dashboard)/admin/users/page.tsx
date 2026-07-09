"use client";

import { ShieldAlert } from "lucide-react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { UserTable } from "@/components/users/user-table";
import { useUsers } from "@/lib/hooks/use-users";
import { useAuth } from "@/providers";

export default function AdminUsersPage() {
  const { user, isLoading: isAuthLoading } = useAuth();
  const isSystemAdmin = !!user?.isSystemAdmin;
  const { data: users = [], isLoading } = useUsers(isSystemAdmin);

  if (isAuthLoading) {
    return (
      <div className="max-w-5xl mx-auto space-y-6">
        <Skeleton className="h-8 w-64 bg-muted" />
        <Skeleton className="h-64 w-full bg-muted" />
      </div>
    );
  }

  if (!isSystemAdmin) {
    return (
      <div className="max-w-5xl mx-auto">
        <div className="text-center py-12">
          <ShieldAlert className="h-10 w-10 mx-auto mb-4 text-muted-foreground" />
          <p className="text-muted-foreground">
            You need system administrator rights to manage users.
          </p>
        </div>
      </div>
    );
  }

  return (
    <div className="max-w-5xl mx-auto space-y-6">
      {/* Header */}
      <div>
        <h2 className="text-2xl font-semibold text-foreground">Users</h2>
        <p className="text-muted-foreground">
          Manage all user accounts on this Strato installation
        </p>
      </div>

      <Card className="bg-card border-border">
        <CardHeader>
          <CardTitle className="text-lg font-semibold text-foreground">
            All Users
          </CardTitle>
        </CardHeader>
        <CardContent>
          <UserTable
            users={users}
            isLoading={isLoading}
            currentUserId={user?.id}
          />
        </CardContent>
      </Card>
    </div>
  );
}
