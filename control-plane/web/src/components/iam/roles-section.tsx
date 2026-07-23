"use client";

import { useState } from "react";
import { Plus } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Card,
  CardContent,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { useRoles } from "@/lib/hooks";
import { RolesTable } from "./roles-table";
import { RoleFormDialog } from "./role-form-dialog";
import type { IAMRole, IAMRoleOwnerType } from "@/types/api";

interface RolesSectionProps {
  ownerType: IAMRoleOwnerType;
  ownerId: string;
  /** Whether the current user can create/edit/delete roles (owner admin). */
  canManage: boolean;
}

export function RolesSection({
  ownerType,
  ownerId,
  canManage,
}: RolesSectionProps) {
  const { data: roles = [], isLoading } = useRoles(ownerType, ownerId);

  const [formOpen, setFormOpen] = useState(false);
  const [editingRole, setEditingRole] = useState<IAMRole | null>(null);

  const handleCreate = () => {
    setEditingRole(null);
    setFormOpen(true);
  };

  const handleEdit = (role: IAMRole) => {
    setEditingRole(role);
    setFormOpen(true);
  };

  return (
    <>
      <Card className="bg-card border-border">
        <CardHeader className="flex flex-row items-center justify-between space-y-0">
          <div>
            <CardTitle className="text-lg font-semibold text-foreground">
              Roles
            </CardTitle>
          </div>
          {canManage && (
            <Button
              size="sm"
              className="bg-primary hover:bg-primary/90"
              onClick={handleCreate}
            >
              <Plus className="h-4 w-4 mr-2" />
              Create role
            </Button>
          )}
        </CardHeader>
        <CardContent>
          <p className="text-sm text-muted-foreground mb-4">
            Roles are named sets of actions, written as Cedar permits. Bind them
            to members here or on projects below.
            {!canManage &&
              " You need admin rights on this owner to create, edit, or delete them."}
          </p>
          <RolesTable
            ownerType={ownerType}
            ownerId={ownerId}
            roles={roles}
            isLoading={isLoading}
            canManage={canManage}
            onEdit={handleEdit}
          />
        </CardContent>
      </Card>

      <RoleFormDialog
        ownerType={ownerType}
        ownerId={ownerId}
        open={formOpen}
        onOpenChange={setFormOpen}
        role={editingRole}
      />
    </>
  );
}
