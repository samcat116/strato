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
import { useGroups } from "@/lib/hooks";
import { GroupsTable } from "./groups-table";
import { GroupFormDialog } from "./group-form-dialog";
import { ManageGroupMembersDialog } from "./manage-group-members-dialog";
import type { Group } from "@/types/api";

interface GroupsSectionProps {
  orgId: string;
  /** Whether the current user can create/edit/delete groups (org admin). */
  canManage: boolean;
}

export function GroupsSection({ orgId, canManage }: GroupsSectionProps) {
  const { data: groups = [], isLoading } = useGroups(orgId);

  const [formOpen, setFormOpen] = useState(false);
  const [editingGroup, setEditingGroup] = useState<Group | null>(null);
  const [membersOpen, setMembersOpen] = useState(false);
  const [membersGroup, setMembersGroup] = useState<Group | null>(null);

  const handleCreate = () => {
    setEditingGroup(null);
    setFormOpen(true);
  };

  const handleEdit = (group: Group) => {
    setEditingGroup(group);
    setFormOpen(true);
  };

  const handleManageMembers = (group: Group) => {
    setMembersGroup(group);
    setMembersOpen(true);
  };

  return (
    <>
      <Card className="bg-gray-800 border-gray-700">
        <CardHeader className="flex flex-row items-center justify-between space-y-0">
          <CardTitle className="text-lg font-semibold text-gray-100">
            Groups
          </CardTitle>
          {canManage && (
            <Button
              size="sm"
              className="bg-blue-600 hover:bg-blue-700"
              onClick={handleCreate}
            >
              <Plus className="h-4 w-4 mr-2" />
              Create Group
            </Button>
          )}
        </CardHeader>
        <CardContent>
          {!canManage && (
            <p className="text-sm text-gray-400 mb-4">
              You need admin rights to create, edit, or delete groups and their
              members.
            </p>
          )}
          <GroupsTable
            orgId={orgId}
            groups={groups}
            isLoading={isLoading}
            canManage={canManage}
            onEdit={handleEdit}
            onManageMembers={handleManageMembers}
          />
        </CardContent>
      </Card>

      <GroupFormDialog
        orgId={orgId}
        open={formOpen}
        onOpenChange={setFormOpen}
        group={editingGroup}
      />

      <ManageGroupMembersDialog
        orgId={orgId}
        group={membersGroup}
        open={membersOpen}
        onOpenChange={setMembersOpen}
        canManage={canManage}
      />
    </>
  );
}
