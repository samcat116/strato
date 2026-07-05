"use client";

import { useState } from "react";
import {
  ChevronDown,
  ChevronRight,
  FolderTree,
  Loader2,
  Pencil,
  Plus,
  Trash2,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import {
  useOrganizationalUnitTree,
  useDeleteOrganizationalUnit,
  ouErrorMessage,
} from "@/lib/hooks";
import { toast } from "sonner";
import type { OrganizationalUnit, OrganizationalUnitTree } from "@/types/api";
import type { EditableOU } from "./ou-form-dialog";

interface OuActionHandlers {
  orgId: string;
  canManage: boolean;
  onEdit: (ou: EditableOU) => void;
  onAddSub: (parent: { id: string; name: string }) => void;
}

interface OuTreeProps extends OuActionHandlers {
  units: OrganizationalUnit[];
  isLoading?: boolean;
}

export function OuTree({ units, isLoading, ...handlers }: OuTreeProps) {
  if (isLoading) {
    return (
      <div className="space-y-2">
        {[...Array(3)].map((_, i) => (
          <Skeleton key={i} className="h-10 w-full bg-gray-700" />
        ))}
      </div>
    );
  }

  if (units.length === 0) {
    return (
      <div className="text-center py-8 text-gray-400">
        No organizational units yet.
      </div>
    );
  }

  return (
    <ul className="space-y-1">
      {units.map((unit) => (
        <OuTopNode key={unit.id} unit={unit} {...handlers} />
      ))}
    </ul>
  );
}

/** A top-level OU. Its subtree is fetched lazily the first time it expands. */
function OuTopNode({
  unit,
  ...handlers
}: { unit: OrganizationalUnit } & OuActionHandlers) {
  const [expanded, setExpanded] = useState(false);
  const hasChildren = (unit.childOuCount ?? 0) > 0;
  const { data: tree, isLoading } = useOrganizationalUnitTree(
    handlers.orgId,
    expanded && hasChildren ? unit.id : undefined
  );

  return (
    <li>
      <OuRow
        id={unit.id}
        name={unit.name}
        description={unit.description}
        depth={0}
        projectCount={unit.projectCount ?? 0}
        childCount={unit.childOuCount ?? 0}
        expanded={expanded}
        onToggle={hasChildren ? () => setExpanded((v) => !v) : undefined}
        {...handlers}
      />
      {expanded && hasChildren && (
        <ul className="space-y-1 mt-1">
          {isLoading && (
            <li style={{ paddingLeft: 28 }}>
              <Skeleton className="h-9 w-full bg-gray-700" />
            </li>
          )}
          {tree?.children.map((child) => (
            <OuTreeNode key={child.id} node={child} {...handlers} />
          ))}
        </ul>
      )}
    </li>
  );
}

/** A descendant OU from an already-loaded subtree. */
function OuTreeNode({
  node,
  ...handlers
}: { node: OrganizationalUnitTree } & OuActionHandlers) {
  const [expanded, setExpanded] = useState(false);
  const hasChildren = node.children.length > 0;

  return (
    <li>
      <OuRow
        id={node.id}
        name={node.name}
        description={node.description}
        depth={node.depth}
        projectCount={node.projectCount}
        childCount={node.children.length}
        expanded={expanded}
        onToggle={hasChildren ? () => setExpanded((v) => !v) : undefined}
        {...handlers}
      />
      {expanded && hasChildren && (
        <ul className="space-y-1 mt-1">
          {node.children.map((child) => (
            <OuTreeNode key={child.id} node={child} {...handlers} />
          ))}
        </ul>
      )}
    </li>
  );
}

interface OuRowProps extends OuActionHandlers {
  id: string;
  name: string;
  description: string;
  depth: number;
  projectCount: number;
  childCount: number;
  expanded: boolean;
  onToggle?: () => void;
}

function OuRow({
  id,
  name,
  description,
  depth,
  projectCount,
  childCount,
  expanded,
  onToggle,
  orgId,
  canManage,
  onEdit,
  onAddSub,
}: OuRowProps) {
  const deleteOU = useDeleteOrganizationalUnit(orgId);
  const [isDeleting, setIsDeleting] = useState(false);

  const handleDelete = async () => {
    if (childCount > 0) {
      toast.error(
        `"${name}" has sub-units. Move or delete them before deleting this unit.`
      );
      return;
    }
    if (projectCount > 0) {
      toast.error(
        `"${name}" has projects. Move or delete them before deleting this unit.`
      );
      return;
    }
    if (!window.confirm(`Delete the organizational unit "${name}"?`)) {
      return;
    }

    setIsDeleting(true);
    try {
      await deleteOU.mutateAsync(id);
      toast.success(`Deleted ${name}`);
    } catch (error) {
      toast.error(ouErrorMessage(error, "Failed to delete organizational unit"));
    } finally {
      setIsDeleting(false);
    }
  };

  return (
    <div
      className="group flex items-center gap-2 rounded-md border border-gray-700 bg-gray-900/40 px-2 py-2 hover:bg-gray-800/60"
      style={{ marginLeft: depth > 0 ? 20 : 0 }}
    >
      {onToggle ? (
        <button
          type="button"
          onClick={onToggle}
          className="text-gray-400 hover:text-gray-100"
          aria-label={expanded ? `Collapse ${name}` : `Expand ${name}`}
        >
          {expanded ? (
            <ChevronDown className="h-4 w-4" />
          ) : (
            <ChevronRight className="h-4 w-4" />
          )}
        </button>
      ) : (
        <span className="w-4" />
      )}

      <FolderTree className="h-4 w-4 text-gray-500 shrink-0" />

      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-2">
          <span className="font-medium text-gray-100 truncate">{name}</span>
          <span className="text-xs text-gray-500 shrink-0">
            {childCount} {childCount === 1 ? "unit" : "units"} · {projectCount}{" "}
            {projectCount === 1 ? "project" : "projects"}
          </span>
        </div>
        {description && (
          <p className="text-xs text-gray-400 truncate">{description}</p>
        )}
      </div>

      {canManage && (
        <div className="flex items-center gap-1 opacity-0 transition-opacity group-hover:opacity-100 focus-within:opacity-100">
          <Button
            size="icon-sm"
            variant="ghost"
            className="text-gray-400 hover:text-gray-100 hover:bg-gray-700"
            onClick={() => onAddSub({ id, name })}
            aria-label={`Add sub-unit to ${name}`}
          >
            <Plus className="h-4 w-4" />
          </Button>
          <Button
            size="icon-sm"
            variant="ghost"
            className="text-gray-400 hover:text-gray-100 hover:bg-gray-700"
            onClick={() => onEdit({ id, name, description })}
            aria-label={`Edit ${name}`}
          >
            <Pencil className="h-4 w-4" />
          </Button>
          <Button
            size="icon-sm"
            variant="ghost"
            className="text-gray-400 hover:text-red-400 hover:bg-red-950/30"
            onClick={handleDelete}
            disabled={isDeleting}
            aria-label={`Delete ${name}`}
          >
            {isDeleting ? (
              <Loader2 className="h-4 w-4 animate-spin" />
            ) : (
              <Trash2 className="h-4 w-4" />
            )}
          </Button>
        </div>
      )}
    </div>
  );
}
