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
  HardDrive,
  Key,
  Layers,
  LayoutGrid,
  MapPin,
  Rows3,
  ScrollText,
  Settings,
  Shield,
  Users,
} from "lucide-react";

export interface NavItem {
  label: string;
  /** Omit for pure grouping toplines (e.g. Storage) that only expand children. */
  href?: string;
  icon: LucideIcon;
  adminOnly?: boolean;
  children?: NavItem[];
}

/**
 * Two-level sidebar tree. Toplines with an `href` are links; toplines with only
 * `children` are collapsible groups. `adminOnly` is now per-item (a group can be
 * visible to everyone while one child inside it is admin-gated).
 */
export const navTree: NavItem[] = [
  { label: "Overview", href: "/dashboard", icon: LayoutGrid },
  {
    label: "Instances",
    href: "/vms",
    icon: Rows3,
    children: [{ label: "Images", href: "/images", icon: Layers }],
  },
  {
    label: "Agents",
    href: "/agents",
    icon: Cpu,
    children: [{ label: "Sites", href: "/sites", icon: MapPin }],
  },
  { label: "Networking", href: "/networks", icon: Globe },
  {
    label: "Storage",
    icon: HardDrive,
    children: [
      { label: "Volumes", href: "/storage/volumes", icon: Database },
      { label: "Snapshots", href: "/storage/snapshots", icon: Camera },
    ],
  },
  {
    label: "Access",
    icon: Shield,
    children: [
      { label: "Projects", href: "/projects", icon: FolderKanban },
      { label: "Hierarchy", href: "/hierarchy", icon: FolderTree },
      { label: "Quotas", href: "/quotas", icon: Gauge },
      { label: "Users", href: "/admin/users", icon: Users, adminOnly: true },
      { label: "API Keys", href: "/settings/api-keys", icon: Key },
    ],
  },
  {
    label: "Settings",
    icon: Settings,
    children: [
      { label: "Organization", href: "/organizations/settings", icon: Building2 },
      { label: "Audit Log", href: "/admin/audit", icon: ScrollText, adminOnly: true },
    ],
  },
];

/** Matches the item's route and any nested route (e.g. /vms/detail highlights Instances). */
export function isNavActive(pathname: string, href: string): boolean {
  return pathname === href || pathname.startsWith(`${href}/`);
}

/** True if this node's own route or any descendant route matches the current path. */
export function isSectionActive(pathname: string, item: NavItem): boolean {
  if (item.href && isNavActive(pathname, item.href)) return true;
  return item.children?.some((child) => isSectionActive(pathname, child)) ?? false;
}

/** All linkable items flattened depth-first (toplines and their children). */
export function flattenNav(nodes: NavItem[] = navTree): NavItem[] {
  return nodes.flatMap((node) => [
    ...(node.href ? [node] : []),
    ...(node.children ? flattenNav(node.children) : []),
  ]);
}

export function pageTitle(pathname: string): string {
  // Prefer the longest matching href so /storage/volumes wins over a shorter prefix.
  const match = flattenNav()
    .filter((item) => item.href && isNavActive(pathname, item.href))
    .sort((a, b) => (b.href!.length ?? 0) - (a.href!.length ?? 0))[0];
  return match?.label ?? "Strato";
}
