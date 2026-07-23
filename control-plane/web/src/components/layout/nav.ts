import type { LucideIcon } from "lucide-react";
import {
  Boxes,
  Building2,
  Camera,
  CircleUser,
  Container,
  Cpu,
  Database,
  Fingerprint,
  FolderKanban,
  Gauge,
  Globe,
  HardDrive,
  Key,
  TerminalSquare,
  Layers,
  LayoutGrid,
  MapPin,
  Rows3,
  Scale,
  ScrollText,
  Server,
  Settings,
  Shield,
  ShieldCheck,
  Users,
  UsersRound,
  Webhook,
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
    label: "Compute",
    icon: Server,
    children: [
      { label: "Instances", href: "/vms", icon: Rows3 },
      { label: "Sandboxes", href: "/sandboxes", icon: Container },
      { label: "Images", href: "/images", icon: Layers },
    ],
  },
  {
    label: "Infrastructure",
    icon: Boxes,
    children: [
      { label: "Agents", href: "/agents", icon: Cpu },
      { label: "Sites", href: "/sites", icon: MapPin },
    ],
  },
  { label: "Networking", href: "/networks", icon: Globe },
  { label: "Security Groups", href: "/security-groups", icon: Shield },
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
      { label: "Quotas", href: "/quotas", icon: Gauge },
      { label: "Users", href: "/admin/users", icon: Users, adminOnly: true },
      { label: "Groups", href: "/access/groups", icon: UsersRound },
      { label: "Roles", href: "/access/roles", icon: ShieldCheck },
      { label: "Policies", href: "/access/policies", icon: Scale },
      { label: "API Keys", href: "/settings/api-keys", icon: Key },
      { label: "CLI Sessions", href: "/settings/cli-sessions", icon: TerminalSquare },
      {
        label: "Workload Identity",
        href: "/workload-identity",
        icon: Fingerprint,
        adminOnly: true,
      },
    ],
  },
  {
    label: "Settings",
    icon: Settings,
    children: [
      // Deployed proxies (deploy/compose/nginx.conf, helm ingress) send the
      // whole /organizations/ prefix to the control plane for SCIM, so
      // frontend pages must not live under it.
      { label: "Profile", href: "/settings/profile", icon: CircleUser },
      { label: "Organization", href: "/settings/organization", icon: Building2 },
      { label: "Webhooks", href: "/settings/webhooks", icon: Webhook },
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
