"use client";

import { usePathname } from "next/navigation";
import { CommandPalette } from "./command-palette";
import { ProjectSwitcher } from "./project-switcher";
import { pageTitle } from "./nav";

export function Header() {
  const pathname = usePathname();

  return (
    <header className="flex h-[52px] shrink-0 items-center gap-3 border-b border-border bg-card px-5">
      <span className="text-[13px] font-semibold">{pageTitle(pathname)}</span>
      <div className="flex-1" />
      <ProjectSwitcher />
      <CommandPalette />
    </header>
  );
}
