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
import { useOrganizationalUnits } from "@/lib/hooks";
import { OuTree } from "./ou-tree";
import { OuFormDialog, type EditableOU } from "./ou-form-dialog";

interface OrganizationalUnitsSectionProps {
  orgId: string;
  /** Whether the current user can create/edit/delete units (org admin). */
  canManage: boolean;
}

export function OrganizationalUnitsSection({
  orgId,
  canManage,
}: OrganizationalUnitsSectionProps) {
  const { data: units = [], isLoading } = useOrganizationalUnits(orgId);

  const [formOpen, setFormOpen] = useState(false);
  const [editing, setEditing] = useState<EditableOU | null>(null);
  const [parent, setParent] = useState<{ id: string; name: string } | null>(
    null
  );

  const handleCreateTopLevel = () => {
    setEditing(null);
    setParent(null);
    setFormOpen(true);
  };

  const handleEdit = (ou: EditableOU) => {
    setEditing(ou);
    setParent(null);
    setFormOpen(true);
  };

  const handleAddSub = (p: { id: string; name: string }) => {
    setEditing(null);
    setParent(p);
    setFormOpen(true);
  };

  return (
    <>
      <Card className="bg-card border-border">
        <CardHeader className="flex flex-row items-center justify-between space-y-0">
          <CardTitle className="text-lg font-semibold text-foreground">
            Organizational Units
          </CardTitle>
          {canManage && (
            <Button
              size="sm"
              className="bg-primary hover:bg-primary/90"
              onClick={handleCreateTopLevel}
            >
              <Plus className="h-4 w-4 mr-2" />
              Create Unit
            </Button>
          )}
        </CardHeader>
        <CardContent>
          {!canManage && (
            <p className="text-sm text-muted-foreground mb-4">
              You need admin rights to create, edit, or delete organizational
              units.
            </p>
          )}
          <OuTree
            orgId={orgId}
            units={units}
            isLoading={isLoading}
            canManage={canManage}
            onEdit={handleEdit}
            onAddSub={handleAddSub}
          />
        </CardContent>
      </Card>

      <OuFormDialog
        orgId={orgId}
        open={formOpen}
        onOpenChange={setFormOpen}
        ou={editing}
        parent={parent}
      />
    </>
  );
}
