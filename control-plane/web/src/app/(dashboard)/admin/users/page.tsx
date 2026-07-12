"use client";

import { useState } from "react";
import { ShieldAlert, UserPlus } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { UserTable } from "@/components/users/user-table";
import { CreateUserDialog } from "@/components/users/create-user-dialog";
import { useUsers } from "@/lib/hooks/use-users";
import { useAuth } from "@/providers";

export default function AdminUsersPage() {
  const { user, isLoading: isAuthLoading } = useAuth();
  const isSystemAdmin = !!user?.isSystemAdmin;
  const { data: users = [], isLoading } = useUsers(isSystemAdmin);
  const [createOpen, setCreateOpen] = useState(false);

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
      <div className="flex items-start justify-between gap-4">
        <div>
          <h2 className="text-2xl font-semibold text-foreground">Users</h2>
          <p className="text-muted-foreground">
            Manage all user accounts on this Strato installation
          </p>
        </div>
        <Button
          className="bg-primary hover:bg-primary/90 shrink-0"
          onClick={() => setCreateOpen(true)}
        >
          <UserPlus className="h-4 w-4 mr-2" />
          Create User
        </Button>
      </div>

      <CreateUserDialog open={createOpen} onOpenChange={setCreateOpen} />

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
