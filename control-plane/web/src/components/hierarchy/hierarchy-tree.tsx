"use client";

import { useState } from "react";
import Link from "next/link";
import {
  ChevronRight,
  Building2,
  FolderTree,
  Boxes,
  Monitor,
  ShieldCheck,
} from "lucide-react";
import { cn } from "@/lib/utils";
import { Badge } from "@/components/ui/badge";
import type {
  OrganizationNode,
  FolderNode,
  ProjectNode,
  VMSummaryNode,
} from "@/types/api";

interface RowProps {
  icon: React.ReactNode;
  label: React.ReactNode;
  depth: number;
  expandable?: boolean;
  expanded?: boolean;
  onToggle?: () => void;
  meta?: React.ReactNode;
  href?: string;
}

function TreeRow({
  icon,
  label,
  depth,
  expandable,
  expanded,
  onToggle,
  meta,
  href,
}: RowProps) {
  const content = (
    <div
      className="flex items-center gap-2 py-1.5 pr-2 rounded-md hover:bg-accent/60 transition-colors"
      style={{ paddingLeft: depth * 20 + 4 }}
    >
      {expandable ? (
        <button
          onClick={(e) => {
            e.preventDefault();
            onToggle?.();
          }}
          className="p-0.5 text-muted-foreground hover:text-foreground"
          aria-label={expanded ? "Collapse" : "Expand"}
        >
          <ChevronRight
            className={cn(
              "h-4 w-4 transition-transform",
              expanded && "rotate-90"
            )}
          />
        </button>
      ) : (
        <span className="w-5" />
      )}
      {icon}
      <span className="text-sm text-foreground truncate">{label}</span>
      {meta}
    </div>
  );

  return href ? (
    <Link href={href} className="block">
      {content}
    </Link>
  ) : (
    content
  );
}

function quotaBadge(count: number) {
  if (count === 0) return null;
  return (
    <Badge
      variant="outline"
      className="border-input text-muted-foreground gap-1 ml-1"
    >
      <ShieldCheck className="h-3 w-3" />
      {count}
    </Badge>
  );
}

function VMRow({ vm, depth }: { vm: VMSummaryNode; depth: number }) {
  return (
    <TreeRow
      depth={depth}
      href={`/vms/detail?id=${vm.id}`}
      icon={<Monitor className="h-4 w-4 text-muted-foreground" />}
      label={vm.name}
      meta={
        <span className="ml-2 flex items-center gap-2 text-xs text-muted-foreground">
          <span>{vm.environment}</span>
          <span className="text-muted-foreground">·</span>
          <span>{vm.status}</span>
          <span className="text-muted-foreground">·</span>
          <span>
            {vm.cpu} vCPU / {vm.memoryGB}GB
          </span>
        </span>
      }
    />
  );
}

function ProjectRow({
  project,
  depth,
}: {
  project: ProjectNode;
  depth: number;
}) {
  const [expanded, setExpanded] = useState(false);
  const hasChildren = project.vms.length > 0;
  return (
    <div>
      <TreeRow
        depth={depth}
        icon={<Boxes className="h-4 w-4 text-emerald-600" />}
        label={project.name}
        expandable={hasChildren}
        expanded={expanded}
        onToggle={() => setExpanded((v) => !v)}
        meta={
          <span className="ml-2 flex items-center text-xs text-muted-foreground">
            {project.vms.length} VM{project.vms.length === 1 ? "" : "s"}
            {quotaBadge(project.quotas.length)}
          </span>
        }
      />
      {expanded &&
        project.vms.map((vm) => (
          <VMRow key={vm.id} vm={vm} depth={depth + 1} />
        ))}
    </div>
  );
}

function FolderRow({ folder, depth }: { folder: FolderNode; depth: number }) {
  const [expanded, setExpanded] = useState(true);
  const hasChildren = folder.childOUs.length > 0 || folder.projects.length > 0;
  return (
    <div>
      <TreeRow
        depth={depth}
        icon={<FolderTree className="h-4 w-4 text-purple-600" />}
        label={folder.name}
        expandable={hasChildren}
        expanded={expanded}
        onToggle={() => setExpanded((v) => !v)}
        meta={quotaBadge(folder.quotas.length)}
      />
      {expanded && (
        <>
          {folder.childOUs.map((child) => (
            <FolderRow key={child.id} folder={child} depth={depth + 1} />
          ))}
          {folder.projects.map((project) => (
            <ProjectRow key={project.id} project={project} depth={depth + 1} />
          ))}
        </>
      )}
    </div>
  );
}

export function HierarchyTree({ org }: { org: OrganizationNode }) {
  return (
    <div className="space-y-0.5">
      <TreeRow
        depth={0}
        icon={<Building2 className="h-4 w-4 text-blue-600" />}
        label={<span className="font-medium">{org.name}</span>}
        meta={quotaBadge(org.quotas.length)}
      />
      {org.organizationalUnits.map((folder) => (
        <FolderRow key={folder.id} folder={folder} depth={1} />
      ))}
      {org.projects.map((project) => (
        <ProjectRow key={project.id} project={project} depth={1} />
      ))}
      {org.organizationalUnits.length === 0 &&
        org.projects.length === 0 && (
          <p className="pl-6 py-2 text-sm text-muted-foreground">
            This organization has no folders or projects yet.
          </p>
        )}
    </div>
  );
}
