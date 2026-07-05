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
  OrganizationalUnitNode,
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
      className="flex items-center gap-2 py-1.5 pr-2 rounded-md hover:bg-gray-700/50 transition-colors"
      style={{ paddingLeft: depth * 20 + 4 }}
    >
      {expandable ? (
        <button
          onClick={(e) => {
            e.preventDefault();
            onToggle?.();
          }}
          className="p-0.5 text-gray-400 hover:text-gray-100"
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
      <span className="text-sm text-gray-200 truncate">{label}</span>
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
      className="border-gray-600 text-gray-400 gap-1 ml-1"
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
      icon={<Monitor className="h-4 w-4 text-gray-400" />}
      label={vm.name}
      meta={
        <span className="ml-2 flex items-center gap-2 text-xs text-gray-500">
          <span>{vm.environment}</span>
          <span className="text-gray-600">·</span>
          <span>{vm.status}</span>
          <span className="text-gray-600">·</span>
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
        icon={<Boxes className="h-4 w-4 text-emerald-400" />}
        label={project.name}
        expandable={hasChildren}
        expanded={expanded}
        onToggle={() => setExpanded((v) => !v)}
        meta={
          <span className="ml-2 flex items-center text-xs text-gray-500">
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

function OURow({ ou, depth }: { ou: OrganizationalUnitNode; depth: number }) {
  const [expanded, setExpanded] = useState(true);
  const hasChildren = ou.childOUs.length > 0 || ou.projects.length > 0;
  return (
    <div>
      <TreeRow
        depth={depth}
        icon={<FolderTree className="h-4 w-4 text-purple-400" />}
        label={ou.name}
        expandable={hasChildren}
        expanded={expanded}
        onToggle={() => setExpanded((v) => !v)}
        meta={quotaBadge(ou.quotas.length)}
      />
      {expanded && (
        <>
          {ou.childOUs.map((child) => (
            <OURow key={child.id} ou={child} depth={depth + 1} />
          ))}
          {ou.projects.map((project) => (
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
        icon={<Building2 className="h-4 w-4 text-blue-400" />}
        label={<span className="font-medium">{org.name}</span>}
        meta={quotaBadge(org.quotas.length)}
      />
      {org.organizationalUnits.map((ou) => (
        <OURow key={ou.id} ou={ou} depth={1} />
      ))}
      {org.projects.map((project) => (
        <ProjectRow key={project.id} project={project} depth={1} />
      ))}
      {org.organizationalUnits.length === 0 &&
        org.projects.length === 0 && (
          <p className="pl-6 py-2 text-sm text-gray-500">
            This organization has no units or projects yet.
          </p>
        )}
    </div>
  );
}
