"use client";

import { useState } from "react";
import { Plus, Users, UsersRound } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { useProjectMembers, usePermissions } from "@/lib/hooks";
import { MembersTable } from "./members-table";
import { GroupGrantsTable } from "./group-grants-table";
import { AddMemberDialog } from "./add-member-dialog";
import { AddGroupDialog } from "./add-group-dialog";

interface ProjectMembersSectionProps {
  projectId: string;
  organizationId: string;
}

export function ProjectMembersSection({
  projectId,
  organizationId,
}: ProjectMembersSectionProps) {
  const { data, isLoading } = useProjectMembers(projectId);
  const { permissions } = usePermissions([
    {
      key: "manage_project",
      resourceType: "project",
      resourceId: projectId,
      permission: "manage_project",
    },
  ]);
  const canManage = permissions.manage_project;

  const [addUserOpen, setAddUserOpen] = useState(false);
  const [addGroupOpen, setAddGroupOpen] = useState(false);

  const users = data?.users ?? [];
  const groups = data?.groups ?? [];

  return (
    <Card className="bg-gray-800 border-gray-700">
      <CardHeader>
        <CardTitle className="text-lg font-semibold text-gray-100">
          Members &amp; access
        </CardTitle>
        {!canManage && (
          <p className="text-sm text-gray-400">
            You need the project admin role to grant or change access.
          </p>
        )}
      </CardHeader>
      <CardContent>
        <Tabs defaultValue="users">
          <div className="flex items-center justify-between mb-4">
            <TabsList className="bg-gray-900">
              <TabsTrigger value="users" className="data-[state=active]:bg-gray-700">
                <Users className="h-4 w-4 mr-2" />
                Users ({users.length})
              </TabsTrigger>
              <TabsTrigger value="groups" className="data-[state=active]:bg-gray-700">
                <UsersRound className="h-4 w-4 mr-2" />
                Groups ({groups.length})
              </TabsTrigger>
            </TabsList>
          </div>

          <TabsContent value="users">
            {canManage && (
              <div className="flex justify-end mb-3">
                <Button
                  size="sm"
                  className="bg-blue-600 hover:bg-blue-700"
                  onClick={() => setAddUserOpen(true)}
                >
                  <Plus className="h-4 w-4 mr-2" />
                  Add member
                </Button>
              </div>
            )}
            <MembersTable
              projectId={projectId}
              members={users}
              isLoading={isLoading}
              canManage={canManage}
            />
          </TabsContent>

          <TabsContent value="groups">
            {canManage && (
              <div className="flex justify-end mb-3">
                <Button
                  size="sm"
                  className="bg-blue-600 hover:bg-blue-700"
                  onClick={() => setAddGroupOpen(true)}
                >
                  <Plus className="h-4 w-4 mr-2" />
                  Grant group
                </Button>
              </div>
            )}
            <GroupGrantsTable
              projectId={projectId}
              grants={groups}
              isLoading={isLoading}
              canManage={canManage}
            />
          </TabsContent>
        </Tabs>
      </CardContent>

      <AddMemberDialog
        projectId={projectId}
        open={addUserOpen}
        onOpenChange={setAddUserOpen}
      />
      <AddGroupDialog
        projectId={projectId}
        organizationId={organizationId}
        excludeGroupIds={groups.map((g) => g.groupId)}
        open={addGroupOpen}
        onOpenChange={setAddGroupOpen}
      />
    </Card>
  );
}
