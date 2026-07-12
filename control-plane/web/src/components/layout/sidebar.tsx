"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { LogOut, Monitor, Moon, Sun } from "lucide-react";
import { useTheme } from "next-themes";
import { cn } from "@/lib/utils";
import { useAuth, useOrganization } from "@/providers";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuRadioGroup,
  DropdownMenuRadioItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { OrganizationSwitcher } from "./organization-switcher";
import { footerNavItems, isNavActive, navSections, type NavItem } from "./nav";
import { versionLabel, versionTitle } from "@/lib/version";

function SidebarLink({ item }: { item: NavItem }) {
  const pathname = usePathname();
  const active = isNavActive(pathname, item.href);
  const Icon = item.icon;

  return (
    <Link
      href={item.href}
      className={cn(
        "flex items-center gap-2.5 rounded-[7px] px-[9px] py-[7px] text-[13px] transition-colors",
        active
          ? "bg-accent font-semibold text-foreground"
          : "font-medium text-foreground/70 hover:bg-muted hover:text-foreground"
      )}
    >
      <Icon className="h-4 w-4 shrink-0" strokeWidth={1.6} />
      {item.label}
    </Link>
  );
}

const themeOptions = [
  { value: "system", label: "System", icon: Monitor },
  { value: "light", label: "Light", icon: Sun },
  { value: "dark", label: "Dark", icon: Moon },
] as const;

function ThemeToggle() {
  // The dropdown content is portaled and only mounts client-side when the menu
  // opens, so reading next-themes' value here can't cause a hydration mismatch.
  // Radio items (rather than plain buttons) keep these in the menu's keyboard
  // roving-focus model so they're reachable without a mouse.
  const { theme = "system", setTheme } = useTheme();

  return (
    <DropdownMenuRadioGroup value={theme} onValueChange={setTheme}>
      {themeOptions.map(({ value, label, icon: Icon }) => (
        <DropdownMenuRadioItem key={value} value={value} className="cursor-pointer">
          <Icon className="h-4 w-4 shrink-0" strokeWidth={1.6} />
          {label}
        </DropdownMenuRadioItem>
      ))}
    </DropdownMenuRadioGroup>
  );
}

function UserCard() {
  const { user, logout } = useAuth();
  const { currentOrg } = useOrganization();

  const role = user?.isSystemAdmin ? "Admin" : (currentOrg?.userRole ?? "Member");

  return (
    <div className="mt-1.5 border-t border-border/60 pt-1.5">
      <DropdownMenu>
        <DropdownMenuTrigger asChild>
          <button className="flex w-full items-center gap-2.5 rounded-[7px] px-2 py-2 text-left transition-colors hover:bg-muted">
            <div className="h-7 w-7 shrink-0 rounded-full bg-gradient-to-br from-muted to-border" />
            <div className="min-w-0 leading-snug">
              <div className="truncate text-xs font-semibold">
                {user?.displayName || user?.username || "—"}
              </div>
              <div className="truncate text-[10.5px] capitalize text-muted-foreground">
                {role}
              </div>
            </div>
          </button>
        </DropdownMenuTrigger>
        <DropdownMenuContent align="start" className="w-56">
          <DropdownMenuLabel className="truncate text-xs font-normal text-muted-foreground">
            {user?.email}
          </DropdownMenuLabel>
          <DropdownMenuSeparator />
          <DropdownMenuLabel className="text-[10px] font-semibold uppercase tracking-[0.6px] text-muted-foreground">
            Theme
          </DropdownMenuLabel>
          <ThemeToggle />
          <DropdownMenuSeparator />
          <DropdownMenuItem onClick={logout} className="cursor-pointer">
            <LogOut className="mr-2 h-4 w-4" />
            Log out
          </DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>
    </div>
  );
}

export function Sidebar() {
  const { user } = useAuth();

  return (
    <aside className="flex w-[236px] shrink-0 flex-col overflow-y-auto border-r border-border bg-card px-3 py-3.5">
      <div className="flex items-center gap-2 px-2 pb-3.5 pt-1">
        <div className="flex h-6 w-6 items-center justify-center rounded-md bg-foreground font-mono text-[13px] font-bold text-background">
          S
        </div>
        <span className="font-mono text-[15px] font-bold tracking-tight">Strato</span>
      </div>

      <OrganizationSwitcher />

      <nav className="flex flex-1 flex-col">
        {navSections
          .filter((section) => !section.adminOnly || user?.isSystemAdmin)
          .map((section, i) => (
            <div key={section.label} className={cn("space-y-0.5", i > 0 && "mt-4")}>
              <div className="px-[9px] pb-1.5 text-[10px] font-semibold uppercase tracking-[0.6px] text-muted-foreground">
                {section.label}
              </div>
              {section.items.map((item) => (
                <SidebarLink key={item.href} item={item} />
              ))}
            </div>
          ))}

        <div className="flex-1" />

        <div className="space-y-0.5">
          {footerNavItems.map((item) => (
            <SidebarLink key={item.href} item={item} />
          ))}
        </div>
        <UserCard />
        <div
          title={versionTitle || undefined}
          className="px-2 pt-2 font-mono text-[10px] text-muted-foreground/70"
        >
          {versionLabel}
        </div>
      </nav>
    </aside>
  );
}
