"use client";

import { useState } from "react";
import {
  ChevronDown,
  ChevronRight,
  FolderTree as FolderTreeIcon,
  Loader2,
  Pencil,
  Plus,
  Trash2,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import {
  useFolderTree,
  useDeleteFolder,
  folderErrorMessage,
} from "@/lib/hooks";
import { toast } from "sonner";
import type { Folder, FolderTreeNode } from "@/types/api";
import type { EditableFolder } from "./folder-form-dialog";

interface FolderActionHandlers {
  orgId: string;
  canManage: boolean;
  onEdit: (folder: EditableFolder) => void;
  onAddSub: (parent: { id: string; name: string }) => void;
}

interface FolderTreeProps extends FolderActionHandlers {
  folders: Folder[];
  isLoading?: boolean;
}

export function FolderTree({ folders, isLoading, ...handlers }: FolderTreeProps) {
  if (isLoading) {
    return (
      <div className="space-y-2">
        {[...Array(3)].map((_, i) => (
          <Skeleton key={i} className="h-10 w-full bg-muted" />
        ))}
      </div>
    );
  }

  if (folders.length === 0) {
    return (
      <div className="text-center py-8 text-muted-foreground">
        No folders yet.
      </div>
    );
  }

  return (
    <ul className="space-y-1">
      {folders.map((folder) => (
        <FolderTopNode key={folder.id} folder={folder} {...handlers} />
      ))}
    </ul>
  );
}

/** A top-level folder. Its subtree is fetched lazily the first time it expands. */
function FolderTopNode({
  folder,
  ...handlers
}: { folder: Folder } & FolderActionHandlers) {
  const [expanded, setExpanded] = useState(false);
  const hasChildren = (folder.childOuCount ?? 0) > 0;
  const { data: tree, isLoading } = useFolderTree(
    handlers.orgId,
    expanded && hasChildren ? folder.id : undefined
  );

  return (
    <li>
      <FolderRow
        id={folder.id}
        name={folder.name}
        description={folder.description}
        depth={0}
        projectCount={folder.projectCount ?? 0}
        childCount={folder.childOuCount ?? 0}
        expanded={expanded}
        onToggle={hasChildren ? () => setExpanded((v) => !v) : undefined}
        {...handlers}
      />
      {expanded && hasChildren && (
        <ul className="space-y-1 mt-1">
          {isLoading && (
            <li style={{ paddingLeft: 28 }}>
              <Skeleton className="h-9 w-full bg-muted" />
            </li>
          )}
          {tree?.children.map((child) => (
            <FolderNode key={child.id} node={child} {...handlers} />
          ))}
        </ul>
      )}
    </li>
  );
}

/** A descendant folder from an already-loaded subtree. */
function FolderNode({
  node,
  ...handlers
}: { node: FolderTreeNode } & FolderActionHandlers) {
  const [expanded, setExpanded] = useState(false);
  const hasChildren = node.children.length > 0;

  return (
    <li>
      <FolderRow
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
            <FolderNode key={child.id} node={child} {...handlers} />
          ))}
        </ul>
      )}
    </li>
  );
}

interface FolderRowProps extends FolderActionHandlers {
  id: string;
  name: string;
  description: string;
  depth: number;
  projectCount: number;
  childCount: number;
  expanded: boolean;
  onToggle?: () => void;
}

function FolderRow({
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
}: FolderRowProps) {
  const deleteFolder = useDeleteFolder(orgId);
  const [isDeleting, setIsDeleting] = useState(false);

  const handleDelete = async () => {
    if (childCount > 0) {
      toast.error(
        `"${name}" has subfolders. Move or delete them before deleting this folder.`
      );
      return;
    }
    if (projectCount > 0) {
      toast.error(
        `"${name}" has projects. Move or delete them before deleting this folder.`
      );
      return;
    }
    if (!window.confirm(`Delete the folder "${name}"?`)) {
      return;
    }

    setIsDeleting(true);
    try {
      await deleteFolder.mutateAsync(id);
      toast.success(`Deleted ${name}`);
    } catch (error) {
      toast.error(folderErrorMessage(error, "Failed to delete folder"));
    } finally {
      setIsDeleting(false);
    }
  };

  return (
    <div
      className="group flex items-center gap-2 rounded-md border border-border bg-muted/40 px-2 py-2 hover:bg-accent/60"
      style={{ marginLeft: depth > 0 ? 20 : 0 }}
    >
      {onToggle ? (
        <button
          type="button"
          onClick={onToggle}
          className="text-muted-foreground hover:text-foreground"
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

      <FolderTreeIcon className="h-4 w-4 text-muted-foreground shrink-0" />

      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-2">
          <span className="font-medium text-foreground truncate">{name}</span>
          <span className="text-xs text-muted-foreground shrink-0">
            {childCount} {childCount === 1 ? "folder" : "folders"} · {projectCount}{" "}
            {projectCount === 1 ? "project" : "projects"}
          </span>
        </div>
        {description && (
          <p className="text-xs text-muted-foreground truncate">{description}</p>
        )}
      </div>

      {canManage && (
        <div className="flex items-center gap-1 opacity-0 transition-opacity group-hover:opacity-100 focus-within:opacity-100">
          <Button
            size="icon-sm"
            variant="ghost"
            className="text-muted-foreground hover:text-foreground hover:bg-accent"
            onClick={() => onAddSub({ id, name })}
            aria-label={`Add subfolder to ${name}`}
          >
            <Plus className="h-4 w-4" />
          </Button>
          <Button
            size="icon-sm"
            variant="ghost"
            className="text-muted-foreground hover:text-foreground hover:bg-accent"
            onClick={() => onEdit({ id, name, description })}
            aria-label={`Edit ${name}`}
          >
            <Pencil className="h-4 w-4" />
          </Button>
          <Button
            size="icon-sm"
            variant="ghost"
            className="text-muted-foreground hover:text-red-600 hover:bg-red-500/10"
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
