import type { LucideIcon } from "lucide-react";
import {
  Building2,
  Camera,
  Cpu,
  Database,
  FolderKanban,
  FolderTree,
  Gauge,
  Globe,
  Key,
  Layers,
  LayoutGrid,
  Rows3,
  ScrollText,
  Users,
} from "lucide-react";

export interface NavItem {
  label: string;
  href: string;
  icon: LucideIcon;
}

export interface NavSection {
  label: string;
  items: NavItem[];
  adminOnly?: boolean;
}

export const navSections: NavSection[] = [
  {
    label: "Platform",
    items: [
      { label: "Overview", href: "/dashboard", icon: LayoutGrid },
      { label: "Instances", href: "/vms", icon: Rows3 },
      { label: "Agents", href: "/agents", icon: Cpu },
      { label: "Networking", href: "/networks", icon: Globe },
      { label: "Images", href: "/images", icon: Layers },
      { label: "Volumes", href: "/storage/volumes", icon: Database },
      { label: "Snapshots", href: "/storage/snapshots", icon: Camera },
    ],
  },
  {
    label: "Organization",
    items: [
      { label: "Projects", href: "/projects", icon: FolderKanban },
      { label: "Hierarchy", href: "/hierarchy", icon: FolderTree },
      { label: "Quotas", href: "/quotas", icon: Gauge },
      { label: "Settings", href: "/organizations/settings", icon: Building2 },
    ],
  },
  {
    label: "Administration",
    adminOnly: true,
    items: [
      { label: "Users", href: "/admin/users", icon: Users },
      { label: "Audit Log", href: "/admin/audit", icon: ScrollText },
    ],
  },
];

export const footerNavItems: NavItem[] = [
  { label: "API Keys", href: "/settings/api-keys", icon: Key },
];

/** Matches the item's route and any nested route (e.g. /vms/detail highlights Instances). */
export function isNavActive(pathname: string, href: string): boolean {
  return pathname === href || pathname.startsWith(`${href}/`);
}

export function pageTitle(pathname: string): string {
  const all = [...navSections.flatMap((s) => s.items), ...footerNavItems];
  // Prefer the longest matching href so /storage/volumes wins over a shorter prefix.
  const match = all
    .filter((item) => isNavActive(pathname, item.href))
    .sort((a, b) => b.href.length - a.href.length)[0];
  return match?.label ?? "Strato";
}
