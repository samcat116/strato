"use client";

import { useState } from "react";
import { Plus, Shield } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import {
  SecurityGroupTable,
  CreateSecurityGroupDialog,
  EditSecurityGroupDialog,
  SecurityGroupRulesDialog,
} from "@/components/security-groups";
import { useSecurityGroups, useInvalidateSecurityGroups } from "@/lib/hooks";
import { useProjectContext } from "@/providers";
import type { SecurityGroup } from "@/types/api";

export default function SecurityGroupsPage() {
  const [createOpen, setCreateOpen] = useState(false);
  const [editing, setEditing] = useState<SecurityGroup | null>(null);
  // The rules dialog tracks an id (not a group object) so rule mutations show
  // up immediately from the refreshed query data.
  const [rulesGroupId, setRulesGroupId] = useState<string | null>(null);
  const { currentProject } = useProjectContext();
  const { data: groups = [], isLoading } = useSecurityGroups(
    currentProject?.id
  );
  const invalidateSecurityGroups = useInvalidateSecurityGroups();

  const rulesGroup = groups.find((group) => group.id === rulesGroupId) ?? null;

  return (
    <div className="max-w-7xl mx-auto space-y-6">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-3">
          <Shield className="h-8 w-8 text-blue-600" />
          <div>
            <h2 className="text-2xl font-semibold text-foreground">
              Security Groups
            </h2>
            <p className="text-muted-foreground">
              {currentProject
                ? `Security groups available in ${currentProject.name}`
                : "Manage the firewall rule sets your VM interfaces attach to"}
            </p>
          </div>
        </div>
        <Button
          className="bg-primary hover:bg-primary/90"
          onClick={() => setCreateOpen(true)}
        >
          <Plus className="h-4 w-4 mr-2" />
          Create Security Group
        </Button>
      </div>

      <Card className="bg-card border-border">
        <CardHeader>
          <CardTitle className="text-lg font-semibold text-foreground">
            {currentProject ? currentProject.name : "All"} Security Groups (
            {groups.length})
          </CardTitle>
        </CardHeader>
        <CardContent>
          <SecurityGroupTable
            groups={groups}
            isLoading={isLoading}
            onRefresh={invalidateSecurityGroups}
            onEdit={setEditing}
            onManageRules={(group) => setRulesGroupId(group.id)}
          />
        </CardContent>
      </Card>

      <CreateSecurityGroupDialog
        open={createOpen}
        onOpenChange={setCreateOpen}
        onCreated={invalidateSecurityGroups}
      />

      <EditSecurityGroupDialog
        group={editing}
        open={editing !== null}
        onOpenChange={(open) => {
          if (!open) setEditing(null);
        }}
        onUpdated={invalidateSecurityGroups}
      />

      <SecurityGroupRulesDialog
        group={rulesGroup}
        groups={groups}
        open={rulesGroup !== null}
        onOpenChange={(open) => {
          if (!open) setRulesGroupId(null);
        }}
        onChanged={invalidateSecurityGroups}
      />
    </div>
  );
}
