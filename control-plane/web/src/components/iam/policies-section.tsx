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
import { usePolicies } from "@/lib/hooks";
import { PoliciesTable } from "./policies-table";
import { PolicyFormDialog } from "./policy-form-dialog";
import type { IAMPolicy, IAMRoleOwnerType } from "@/types/api";

interface PoliciesSectionProps {
  ownerType: IAMRoleOwnerType;
  ownerId: string;
  /** Whether the current user can create/edit/delete policies (owner admin). */
  canManage: boolean;
}

export function PoliciesSection({
  ownerType,
  ownerId,
  canManage,
}: PoliciesSectionProps) {
  const { data: policies = [], isLoading } = usePolicies(ownerType, ownerId);

  const [formOpen, setFormOpen] = useState(false);
  const [editingPolicy, setEditingPolicy] = useState<IAMPolicy | null>(null);

  const handleCreate = () => {
    setEditingPolicy(null);
    setFormOpen(true);
  };

  const handleEdit = (policy: IAMPolicy) => {
    setEditingPolicy(policy);
    setFormOpen(true);
  };

  return (
    <>
      <Card className="bg-card border-border">
        <CardHeader className="flex flex-row items-center justify-between space-y-0">
          <CardTitle className="text-lg font-semibold text-foreground">
            Policies
          </CardTitle>
          {canManage && (
            <Button
              size="sm"
              className="bg-primary hover:bg-primary/90"
              onClick={handleCreate}
            >
              <Plus className="h-4 w-4 mr-2" />
              Create policy
            </Button>
          )}
        </CardHeader>
        <CardContent>
          <p className="text-sm text-muted-foreground mb-4">
            Authored Cedar permits and forbids scoped to this owner&apos;s
            subtree. A forbid ceilings access even over a role grant.
            {!canManage &&
              " You need admin rights on this owner to create, edit, or delete them."}
          </p>
          <PoliciesTable
            ownerType={ownerType}
            ownerId={ownerId}
            policies={policies}
            isLoading={isLoading}
            canManage={canManage}
            onEdit={handleEdit}
          />
        </CardContent>
      </Card>

      <PolicyFormDialog
        ownerType={ownerType}
        ownerId={ownerId}
        open={formOpen}
        onOpenChange={setFormOpen}
        policy={editingPolicy}
      />
    </>
  );
}
