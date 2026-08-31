"use client";

import type { Dispatch, SetStateAction } from "react";
import {
  ChevronLeft,
  ChevronRight,
  MoreHorizontal,
  Pencil,
  Plus,
  Search,
  Trash2,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { Input } from "@/components/ui/input";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import type { Agent, Site, VM } from "@/types/api";
import {
  STATUS_STYLES,
  siteCapacity,
  siteInstances,
  siteMembers,
  displayStatus,
  type StatusFilter,
} from "./site-model";

interface SiteListState {
  query: string;
  setQuery: (query: string) => void;
  pageItems: Site[];
  totalPages: number;
  page: number;
  setPage: (page: number) => void;
  filteredCount: number;
}

interface SitesTableProps {
  sites: Site[];
  isLoading: boolean;
  agents: Agent[];
  vms: VM[];
  agentsKnown: boolean;
  vmsKnown: boolean;
  list: SiteListState;
  statusFilter: StatusFilter;
  setStatusFilter: Dispatch<SetStateAction<StatusFilter>>;
  canCreate: boolean;
  canManage: (site: Site) => boolean;
  deletePending: boolean;
  deletingSiteId?: string;
  onCreate: () => void;
  onEdit: (site: Site) => void;
  onDelete: (site: Site) => void;
}

export function SitesTable({
  sites,
  isLoading,
  agents,
  vms,
  agentsKnown,
  vmsKnown,
  list,
  statusFilter,
  setStatusFilter,
  canCreate,
  canManage,
  deletePending,
  deletingSiteId,
  onCreate,
  onEdit,
  onDelete,
}: SitesTableProps) {
  return (
    <section className="overflow-hidden rounded-[11px] border border-border bg-card">
      <div className="flex flex-col gap-3 border-b border-border px-4 py-3 sm:flex-row sm:items-center">
        <div className="flex items-baseline gap-2">
          <h2 className="text-[13.5px] font-semibold">All sites</h2>
          <span className="font-mono text-[11.5px] text-muted-foreground">
            {sites.length}
          </span>
        </div>
        <div className="flex-1" />
        <div className="relative w-full sm:w-52">
          <Search className="absolute left-2.5 top-2.5 h-3.5 w-3.5 text-muted-foreground" />
          <Input
            type="search"
            aria-label="Search sites"
            placeholder="Search sites…"
            value={list.query}
            onChange={(event) => list.setQuery(event.target.value)}
            className="h-8 pl-8 text-[12px]"
          />
        </div>
        <div className="flex gap-1.5 overflow-x-auto">
          {(["all", "healthy", "degraded", "provisioning"] as StatusFilter[]).map(
            (filter) => (
              <Button
                key={filter}
                type="button"
                size="sm"
                variant={statusFilter === filter ? "default" : "outline"}
                className="h-8 rounded-full px-3 text-[11.5px] capitalize"
                onClick={() => setStatusFilter(filter)}
              >
                {filter}
              </Button>
            )
          )}
        </div>
      </div>
    
      {isLoading ? (
        <div className="space-y-2 p-4">
          {Array.from({ length: 4 }).map((_, index) => (
            <Skeleton key={index} className="h-14 w-full" />
          ))}
        </div>
      ) : sites.length === 0 ? (
        <div className="px-4 py-12 text-center">
          <div className="text-[13.5px] font-semibold">No sites yet</div>
          <p className="mx-auto mt-1 max-w-md text-[12.5px] text-muted-foreground">
            Sites are availability zones whose agents share one network fabric.
          </p>
          {canCreate && (
            <Button size="sm" className="mt-4" onClick={onCreate}>
              <Plus className="h-3.5 w-3.5" />
              Create the first site
            </Button>
          )}
        </div>
      ) : list.pageItems.length === 0 ? (
        <div className="px-4 py-10 text-center text-[12.5px] text-muted-foreground">
          No sites match the current search and filter.
        </div>
      ) : (
        <Table>
          <TableHeader>
            <TableRow className="border-border hover:bg-transparent">
              <TableHead className="w-10 px-4" />
              <TableHead className="text-[10.5px] font-semibold uppercase tracking-[0.4px] text-muted-foreground">Site</TableHead>
              <TableHead className="text-[10.5px] font-semibold uppercase tracking-[0.4px] text-muted-foreground">Region</TableHead>
              <TableHead className="text-[10.5px] font-semibold uppercase tracking-[0.4px] text-muted-foreground">Agents</TableHead>
              <TableHead className="text-[10.5px] font-semibold uppercase tracking-[0.4px] text-muted-foreground">Instances</TableHead>
              <TableHead className="min-w-52 text-[10.5px] font-semibold uppercase tracking-[0.4px] text-muted-foreground">Capacity</TableHead>
              <TableHead className="text-[10.5px] font-semibold uppercase tracking-[0.4px] text-muted-foreground">Controller</TableHead>
              <TableHead className="text-[10.5px] font-semibold uppercase tracking-[0.4px] text-muted-foreground">Lifecycle</TableHead>
              <TableHead className="w-12" />
            </TableRow>
          </TableHeader>
          <TableBody>
            {list.pageItems.map((site) => {
              const members = siteMembers(site.id, agents);
              const instances = siteInstances(site.id, agents, vms);
              const capacity = siteCapacity(members);
              const status = displayStatus(site, members, agentsKnown);
              const controller = site.networkControllerAgentId
                ? agents.find(
                    (agent) =>
                      agent.id.toLowerCase() ===
                      site.networkControllerAgentId!.toLowerCase()
                  )
                : undefined;
              return (
                <TableRow key={site.id} className="border-border hover:bg-background/60">
                  <TableCell className="px-4">
                    <span className="block h-2.5 w-2.5 rounded-full" style={{ background: STATUS_STYLES[status].dot }} title={STATUS_STYLES[status].label} />
                  </TableCell>
                  <TableCell>
                    <div className="font-mono text-[13px] font-semibold">{site.name}</div>
                    <div className="max-w-48 truncate font-mono text-[11px] text-muted-foreground">
                      {site.locationLabel || site.description || "No location set"}
                    </div>
                  </TableCell>
                  <TableCell className="font-mono text-[12.5px] text-muted-foreground">{site.regionCode || "—"}</TableCell>
                  <TableCell className="font-mono text-[12.5px] text-muted-foreground">{agentsKnown ? members.length : "—"}</TableCell>
                  <TableCell className="font-mono text-[12.5px] text-muted-foreground">{vmsKnown && agentsKnown ? instances.length : "—"}</TableCell>
                  <TableCell>
                    {agentsKnown ? (
                      <div className="flex min-w-44 items-center gap-2">
                        <div className="h-1.5 flex-1 overflow-hidden rounded-full bg-muted" role="progressbar" aria-label={`${site.name} reserved vCPU`} aria-valuemin={0} aria-valuemax={100} aria-valuenow={capacity}>
                          <div className="h-full rounded-full bg-foreground" style={{ width: `${capacity}%` }} />
                        </div>
                        <span className="w-9 font-mono text-[11.5px] text-muted-foreground">{members.some((agent) => agent.isOnline) ? `${capacity}%` : "—"}</span>
                      </div>
                    ) : <span className="text-muted-foreground">—</span>}
                  </TableCell>
                  <TableCell>
                    <div className="max-w-44 truncate font-mono text-[11.5px] text-muted-foreground">
                      {site.networkControllerIssue
                        ? "Unavailable"
                        : controller?.name ?? (site.networkControllerAgentId ? `${site.networkControllerAgentId.slice(0, 8)}…` : "Not designated")}
                    </div>
                  </TableCell>
                  <TableCell>
                    <span className="rounded-full bg-muted px-2 py-1 font-mono text-[10.5px] capitalize text-foreground/75">{site.status}</span>
                  </TableCell>
                  <TableCell className="pr-3 text-right">
                    {canManage(site) && (
                      <DropdownMenu>
                        <DropdownMenuTrigger asChild>
                          <Button variant="ghost" size="icon-sm" aria-label={`Actions for ${site.name}`} disabled={deletePending && deletingSiteId === site.id}>
                            <MoreHorizontal className="h-4 w-4" />
                          </Button>
                        </DropdownMenuTrigger>
                        <DropdownMenuContent align="end">
                          <DropdownMenuItem onClick={() => onEdit(site)}>
                            <Pencil className="mr-2 h-4 w-4" />Edit site
                          </DropdownMenuItem>
                          <DropdownMenuSeparator />
                          <DropdownMenuItem variant="destructive" onClick={() => onDelete(site)}>
                            <Trash2 className="mr-2 h-4 w-4" />Delete site
                          </DropdownMenuItem>
                        </DropdownMenuContent>
                      </DropdownMenu>
                    )}
                  </TableCell>
                </TableRow>
              );
            })}
          </TableBody>
        </Table>
      )}
    
      {list.totalPages > 1 && (
        <div className="flex items-center justify-between border-t border-border px-4 py-3 font-mono text-[11.5px] text-muted-foreground">
          <span>Page {list.page} of {list.totalPages} · {list.filteredCount} results</span>
          <div className="flex gap-1">
            <Button variant="outline" size="icon-sm" aria-label="Previous page" disabled={list.page <= 1} onClick={() => list.setPage(list.page - 1)}><ChevronLeft className="h-4 w-4" /></Button>
            <Button variant="outline" size="icon-sm" aria-label="Next page" disabled={list.page >= list.totalPages} onClick={() => list.setPage(list.page + 1)}><ChevronRight className="h-4 w-4" /></Button>
          </div>
        </div>
      )}
    </section>
  );
}
