"use client";

import { useState } from "react";
import {
  Plus,
  Server,
  Users,
  UsersRound,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import {
  useProjectMembers,
  usePermissions,
  useProjectVMPrincipals,
} from "@/lib/hooks";
import { MembersTable } from "./members-table";
import { GroupGrantsTable } from "./group-grants-table";
import { AddMemberDialog } from "./add-member-dialog";
import { AddGroupDialog } from "./add-group-dialog";
import { VMGrantsTable } from "./vm-grants-table";

interface ProjectMembersSectionProps {
  projectId: string;
  organizationId: string;
}

export function ProjectMembersSection({
  projectId,
  organizationId,
}: ProjectMembersSectionProps) {
  const { data, isLoading } = useProjectMembers(projectId);
  const { data: vms = [], isLoading: vmsLoading } =
    useProjectVMPrincipals(projectId);
  const { permissions } = usePermissions([
    {
      key: "set_policy",
      action: "iam:setPolicy",
      node: { type: "project", id: projectId },
    },
  ]);
  const canManage = permissions.set_policy;

  const [addUserOpen, setAddUserOpen] = useState(false);
  const [addGroupOpen, setAddGroupOpen] = useState(false);

  const users = data?.users ?? [];
  const groups = data?.groups ?? [];
  const workloads = data?.workloads ?? [];

  return (
    <Card className="bg-card border-border">
      <CardHeader>
        <CardTitle className="text-lg font-semibold text-foreground">
          Members &amp; access
        </CardTitle>
        {!canManage && (
          <p className="text-sm text-muted-foreground">
            You need the project admin role to grant or change access.
          </p>
        )}
      </CardHeader>
      <CardContent>
        <Tabs defaultValue="users">
          <div className="flex items-center justify-between mb-4">
            <TabsList className="bg-background">
              <TabsTrigger value="users" className="data-[state=active]:bg-muted">
                <Users className="h-4 w-4 mr-2" />
                Users ({users.length})
              </TabsTrigger>
              <TabsTrigger value="groups" className="data-[state=active]:bg-muted">
                <UsersRound className="h-4 w-4 mr-2" />
                Groups ({groups.length})
              </TabsTrigger>
              <TabsTrigger value="vms" className="data-[state=active]:bg-muted">
                <Server className="h-4 w-4 mr-2" />
                VMs ({vms.length})
              </TabsTrigger>
            </TabsList>
          </div>

          <TabsContent value="users">
            {canManage && (
              <div className="flex justify-end mb-3">
                <Button
                  size="sm"
                  className="bg-primary hover:bg-primary/90"
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
                  className="bg-primary hover:bg-primary/90"
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

          <TabsContent value="vms">
            <p className="mb-3 text-sm text-muted-foreground">
              A role granted here is usable by anything running inside that VM.
            </p>
            <VMGrantsTable
              projectId={projectId}
              vms={vms}
              grants={workloads.filter((grant) => grant.vmId != null)}
              isLoading={isLoading || vmsLoading}
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
