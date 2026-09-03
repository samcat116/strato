"use client";

import { usePathname } from "next/navigation";
import { useState } from "react";
import { Menu } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogTitle,
} from "@/components/ui/dialog";
import { CommandPalette } from "./command-palette";
import { Sidebar } from "./sidebar";
import { pageTitle } from "./nav";

export function Header() {
  const pathname = usePathname();
  const [navigationOpen, setNavigationOpen] = useState(false);

  return (
    <header className="flex h-[52px] shrink-0 items-center gap-3 border-b border-border bg-card px-5">
      <Button
        variant="ghost"
        size="icon"
        className="lg:hidden"
        aria-label="Open navigation"
        onClick={() => setNavigationOpen(true)}
      >
        <Menu className="h-4 w-4" />
      </Button>
      <Dialog open={navigationOpen} onOpenChange={setNavigationOpen}>
        <DialogContent className="left-0 top-0 h-screen w-[280px] max-w-[85vw] translate-x-0 translate-y-0 rounded-none p-0">
          <DialogTitle className="sr-only">Navigation</DialogTitle>
          <DialogDescription className="sr-only">
            Main application navigation
          </DialogDescription>
          <Sidebar
            className="h-full w-full border-r-0"
            onNavigate={() => setNavigationOpen(false)}
          />
        </DialogContent>
      </Dialog>
      <span className="text-[13px] font-semibold">{pageTitle(pathname)}</span>
      <div className="flex-1" />
      <CommandPalette />
    </header>
  );
}
