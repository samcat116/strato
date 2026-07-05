"use client";

import { useState } from "react";
import Link from "next/link";
import { usePathname } from "next/navigation";
import {
  ChevronRight,
  LayoutDashboard,
  Monitor,
  HardDrive,
  Server,
  Settings,
  Plus,
  Key,
  FolderKanban,
} from "lucide-react";
import { cn } from "@/lib/utils";

interface SidebarSectionProps {
  id: string;
  title: string;
  icon: React.ReactNode;
  children: React.ReactNode;
  defaultOpen?: boolean;
}

function SidebarSection({
  id,
  title,
  icon,
  children,
  defaultOpen = false,
}: SidebarSectionProps) {
  // Initialize state from localStorage (lazy initializer avoids effect)
  const [isOpen, setIsOpen] = useState(() => {
    if (typeof window === "undefined") return defaultOpen;
    const stored = localStorage.getItem(`sidebar-${id}`);
    return stored === "expanded" ? true : stored === "collapsed" ? false : defaultOpen;
  });

  const toggle = () => {
    const newState = !isOpen;
    setIsOpen(newState);
    localStorage.setItem(`sidebar-${id}`, newState ? "expanded" : "collapsed");
  };

  return (
    <div className="space-y-1">
      <button
        onClick={toggle}
        className="flex items-center w-full px-3 py-2 text-sm font-medium rounded-md text-gray-300 hover:bg-gray-700 transition-colors"
      >
        <ChevronRight
          className={cn(
            "h-4 w-4 mr-2 transition-transform",
            isOpen && "rotate-90"
          )}
        />
        {icon}
        <span className="ml-2">{title}</span>
      </button>
      {isOpen && <div className="ml-6 space-y-1">{children}</div>}
    </div>
  );
}

interface SidebarLinkProps {
  href: string;
  children: React.ReactNode;
  onClick?: () => void;
}

function SidebarDisabledLink({
  children,
  tooltip,
}: {
  children: React.ReactNode;
  tooltip: string;
}) {
  return (
    <span
      title={tooltip}
      aria-disabled="true"
      className="flex items-center justify-between px-3 py-2 text-sm rounded-md text-gray-500 cursor-not-allowed"
    >
      {children}
      <span className="ml-2 px-1.5 py-0.5 text-[10px] font-medium uppercase tracking-wide rounded bg-gray-700 text-gray-400">
        Soon
      </span>
    </span>
  );
}

function SidebarLink({ href, children, onClick }: SidebarLinkProps) {
  const pathname = usePathname();
  const isActive = pathname === href;

  return (
    <Link
      href={href}
      onClick={onClick}
      className={cn(
        "block px-3 py-2 text-sm rounded-md transition-colors",
        isActive
          ? "bg-gray-700 text-gray-100"
          : "text-gray-400 hover:bg-gray-700 hover:text-gray-200"
      )}
    >
      {children}
    </Link>
  );
}

interface SidebarProps {
  onCreateVM?: () => void;
  onAddAgent?: () => void;
}

export function Sidebar({ onCreateVM, onAddAgent }: SidebarProps) {
  return (
    <aside className="w-64 bg-gray-800 border-r border-gray-700 overflow-y-auto">
      <nav className="px-3 py-4 space-y-1">
        {/* Dashboard Link */}
        <SidebarLink href="/dashboard">
          <span className="flex items-center">
            <LayoutDashboard className="h-4 w-4 mr-2" />
            Dashboard
          </span>
        </SidebarLink>

        {/* Projects Link */}
        <SidebarLink href="/projects">
          <span className="flex items-center">
            <FolderKanban className="h-4 w-4 mr-2" />
            Projects
          </span>
        </SidebarLink>

        {/* VMs Section */}
        <SidebarSection
          id="vms-section"
          title="Virtual Machines"
          icon={<Monitor className="h-4 w-4" />}
          defaultOpen
        >
          <SidebarLink href="/vms">All VMs</SidebarLink>
          <button
            onClick={onCreateVM}
            className="flex items-center w-full px-3 py-2 text-sm text-blue-400 hover:bg-gray-700 rounded-md transition-colors"
          >
            <Plus className="h-4 w-4 mr-2" />
            New VM
          </button>
        </SidebarSection>

        {/* Storage Section */}
        <SidebarSection
          id="storage-section"
          title="Storage"
          icon={<HardDrive className="h-4 w-4" />}
          defaultOpen
        >
          <SidebarLink href="/images">Images</SidebarLink>
          <SidebarDisabledLink tooltip="Volume management is coming soon">
            Volumes
          </SidebarDisabledLink>
          <SidebarDisabledLink tooltip="Volume snapshots are coming soon">
            Snapshots
          </SidebarDisabledLink>
        </SidebarSection>

        {/* Nodes Section */}
        <SidebarSection
          id="nodes-section"
          title="Compute Nodes"
          icon={<Server className="h-4 w-4" />}
        >
          <SidebarLink href="/agents">Agents</SidebarLink>
          <button
            onClick={onAddAgent}
            className="flex items-center w-full px-3 py-2 text-sm text-blue-400 hover:bg-gray-700 rounded-md transition-colors"
          >
            <Plus className="h-4 w-4 mr-2" />
            Add Agent
          </button>
        </SidebarSection>

        {/* Settings Section */}
        <SidebarSection
          id="settings-section"
          title="Settings"
          icon={<Settings className="h-4 w-4" />}
        >
          <SidebarLink href="/organizations/settings">Organization</SidebarLink>
          <SidebarLink href="/settings/api-keys">
            <span className="flex items-center">
              <Key className="h-4 w-4 mr-2" />
              API Keys
            </span>
          </SidebarLink>
        </SidebarSection>
      </nav>
    </aside>
  );
}
