"use client";

import { useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { useQuery } from "@tanstack/react-query";
import { FolderKanban, Rows3, Search, type LucideIcon } from "lucide-react";
import { Dialog, DialogContent, DialogTitle } from "@/components/ui/dialog";
import { cn } from "@/lib/utils";
import { hierarchyApi } from "@/lib/api/hierarchy";
import { useAuth, useOrganization } from "@/providers";
import { flattenNav } from "./nav";

interface PaletteEntry {
  key: string;
  label: string;
  hint: string;
  href: string;
  icon: LucideIcon;
}

export function CommandPalette() {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const [selected, setSelected] = useState(0);
  const router = useRouter();
  const { user } = useAuth();

  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === "k" && (e.metaKey || e.ctrlKey)) {
        e.preventDefault();
        setOpen((o) => !o);
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, []);

  // Search through the bounded, permission-filtered server endpoint instead of
  // downloading every VM and agent whenever the palette opens.
  const { currentOrg, isLoading: orgLoading } = useOrganization();
  const organizationId = currentOrg?.id;

  const normalizedQuery = query.trim();
  const { data: hierarchySearch } = useQuery({
    queryKey: ["hierarchy-search", organizationId, normalizedQuery],
    queryFn: ({ signal }) => hierarchyApi.search(organizationId!, normalizedQuery, undefined, signal),
    enabled: open && !orgLoading && !!organizationId && normalizedQuery.length >= 2,
    staleTime: 30_000,
  });

  const isAdmin = user?.isSystemAdmin ?? false;

  const entries = useMemo<PaletteEntry[]>(() => {
    const pages = flattenNav()
      .filter((item) => !item.adminOnly || isAdmin)
      .map((item) => ({
        key: `page:${item.href}`,
        label: item.label,
        hint: "Page",
        href: item.href!,
        icon: item.icon,
      }));
    const results = (hierarchySearch?.results ?? []).map((result) => ({
      key: `${result.type}:${result.id}`,
      label: result.name,
      hint: result.type === "vm" ? "Instance" : result.type === "project" ? "Project" : "Folder",
      href: result.type === "vm" ? `/vms/${result.id}` : result.type === "project" ? `/projects/${result.id}` : "/hierarchy",
      icon: result.type === "vm" ? Rows3 : FolderKanban,
    }));
    return [...pages, ...results];
  }, [hierarchySearch, isAdmin]);

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return entries.slice(0, 12);
    return entries
      .filter((e) => e.label.toLowerCase().includes(q))
      .slice(0, 12);
  }, [entries, query]);

  const openEntry = (entry: PaletteEntry | undefined) => {
    if (!entry) return;
    setOpen(false);
    router.push(entry.href);
  };

  const onOpenChange = (next: boolean) => {
    setOpen(next);
    if (!next) {
      setQuery("");
      setSelected(0);
    }
  };

  return (
    <>
      <button
        onClick={() => setOpen(true)}
        aria-label="Open search"
        className="flex h-8 w-9 items-center justify-center gap-2 rounded-[7px] border border-border bg-background px-2.5 text-[12.5px] text-muted-foreground transition-colors hover:bg-accent sm:w-64 sm:justify-start"
      >
        <Search className="h-3.5 w-3.5" strokeWidth={1.6} />
        <span className="hidden flex-1 text-left sm:block">Search…</span>
        <span className="hidden rounded border border-border bg-card px-1.5 py-px text-[10.5px] sm:block">
          ⌘K
        </span>
      </button>
      <Dialog open={open} onOpenChange={onOpenChange}>
        <DialogContent className="top-[20%] translate-y-0 gap-0 overflow-hidden p-0 sm:max-w-lg">
          <DialogTitle className="sr-only">Search</DialogTitle>
          <div className="flex items-center gap-2 border-b border-border px-3">
            <Search className="h-4 w-4 shrink-0 text-muted-foreground" strokeWidth={1.6} />
            <input
              autoFocus
              value={query}
              onChange={(e) => {
                setQuery(e.target.value);
                setSelected(0);
              }}
              onKeyDown={(e) => {
                if (e.key === "ArrowDown") {
                  e.preventDefault();
                  setSelected((s) => Math.min(s + 1, filtered.length - 1));
                } else if (e.key === "ArrowUp") {
                  e.preventDefault();
                  setSelected((s) => Math.max(s - 1, 0));
                } else if (e.key === "Enter") {
                  e.preventDefault();
                  openEntry(filtered[selected]);
                }
              }}
              placeholder="Search pages, instances, projects…"
              className="h-11 flex-1 bg-transparent text-sm outline-none placeholder:text-muted-foreground"
            />
          </div>
          <div className="max-h-72 overflow-y-auto p-1.5">
            {filtered.length === 0 ? (
              <div className="px-3 py-6 text-center text-sm text-muted-foreground">
                No results for &ldquo;{query}&rdquo;
              </div>
            ) : (
              filtered.map((entry, i) => {
                const Icon = entry.icon;
                return (
                  <button
                    key={entry.key}
                    onClick={() => openEntry(entry)}
                    onMouseEnter={() => setSelected(i)}
                    className={cn(
                      "flex w-full items-center gap-2.5 rounded-md px-2.5 py-2 text-left text-[13px]",
                      i === selected && "bg-accent"
                    )}
                  >
                    <Icon className="h-4 w-4 shrink-0 text-muted-foreground" strokeWidth={1.6} />
                    <span className="flex-1 truncate">{entry.label}</span>
                    <span className="text-[10.5px] uppercase tracking-wide text-muted-foreground">
                      {entry.hint}
                    </span>
                  </button>
                );
              })
            )}
          </div>
        </DialogContent>
      </Dialog>
    </>
  );
}
