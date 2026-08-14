"use client";

import { useMemo, useState, type FormEvent } from "react";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import {
  ChevronLeft,
  ChevronRight,
  Loader2,
  MoreHorizontal,
  Pencil,
  Plus,
  Search,
  Trash2,
} from "lucide-react";
import { toast } from "sonner";
import { KpiCard, reservedPercent } from "@/components/overview";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { QueryErrorNotice } from "@/components/ui/query-error-notice";
import { useResourceList } from "@/components/ui/resource-list-controls";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { sitesApi } from "@/lib/api/sites";
import {
  isAgentsForbidden,
  useAgents,
  usePermissions,
  useSites,
  useVMs,
} from "@/lib/hooks";
import { cn } from "@/lib/utils";
import { useOrganization } from "@/providers";
import type { Agent, Site, SiteStatus, UpdateSiteRequest, VM } from "@/types/api";

const SITE_STATUSES: SiteStatus[] = [
  "active",
  "draining",
  "maintenance",
  "decommissioned",
];

type DisplayStatus = "healthy" | "degraded" | "provisioning";
type StatusFilter = "all" | DisplayStatus;

const STATUS_STYLES: Record<DisplayStatus, { label: string; dot: string }> = {
  healthy: { label: "Healthy", dot: "#16a34a" },
  degraded: { label: "Degraded", dot: "#d97706" },
  provisioning: { label: "Provisioning", dot: "#94a3b8" },
};

interface SiteFormState {
  name: string;
  description: string;
  status: SiteStatus;
  regionCode: string;
  locationLabel: string;
  latitude: string;
  longitude: string;
  labels: Array<{ key: string; value: string }>;
  networkControllerAgentId: string;
}

const EMPTY_FORM: SiteFormState = {
  name: "",
  description: "",
  status: "active",
  regionCode: "",
  locationLabel: "",
  latitude: "",
  longitude: "",
  labels: [],
  networkControllerAgentId: "",
};

function displayStatus(
  site: Site,
  members: Agent[],
  agentsKnown: boolean
): DisplayStatus {
  if (agentsKnown && members.length === 0 && site.status === "active") {
    return "provisioning";
  }
  if (
    site.status === "active" &&
    site.networkControllerAgentId &&
    !site.networkControllerIssue &&
    (!site.networkControllerStatus || site.networkControllerStatus === "online")
  ) {
    return "healthy";
  }
  return "degraded";
}

function siteMembers(siteId: string, agents: Agent[]): Agent[] {
  return agents.filter((agent) => agent.siteId === siteId);
}

function siteInstances(siteId: string, agents: Agent[], vms: VM[]): VM[] {
  const agentIds = new Set(
    agents
      .filter((agent) => agent.siteId === siteId)
      .map((agent) => agent.id.toLowerCase())
  );
  return vms.filter(
    (vm) => vm.hypervisorId && agentIds.has(vm.hypervisorId.toLowerCase())
  );
}

function siteCapacity(members: Agent[]): number {
  const online = members.filter((agent) => agent.isOnline);
  const total = online.reduce((sum, agent) => sum + agent.resources.totalCPU, 0);
  const available = online.reduce(
    (sum, agent) => sum + agent.resources.availableCPU,
    0
  );
  return reservedPercent(total, available);
}

function SiteFootprint({
  sites,
  agents,
  agentsKnown,
  canManage,
  onEdit,
}: {
  sites: Site[];
  agents: Agent[];
  agentsKnown: boolean;
  canManage: (site: Site) => boolean;
  onEdit: (site: Site) => void;
}) {
  const mappedSites = sites.filter(
    (site) =>
      typeof site.latitude === "number" && typeof site.longitude === "number"
  );
  const regionCount = new Set(
    sites.map((site) => site.regionCode).filter((region): region is string => !!region)
  ).size;

  return (
    <section className="overflow-hidden rounded-[11px] border border-border bg-card">
      <div className="flex flex-col gap-3 border-b border-border px-[18px] py-3.5 sm:flex-row sm:items-center">
        <div className="flex items-baseline gap-3">
          <h2 className="text-[13.5px] font-semibold">Global footprint</h2>
          <span className="font-mono text-[11.5px] text-muted-foreground">
            {sites.length} {sites.length === 1 ? "site" : "sites"} · {regionCount}{" "}
            {regionCount === 1 ? "region" : "regions"}
          </span>
        </div>
        <div className="flex-1" />
        <div className="flex flex-wrap gap-4 font-mono text-[11.5px] text-muted-foreground">
          {(Object.keys(STATUS_STYLES) as DisplayStatus[]).map((status) => (
            <span key={status} className="flex items-center gap-1.5">
              <span
                className="h-2.5 w-2.5 rounded-full"
                style={{ background: STATUS_STYLES[status].dot }}
              />
              {STATUS_STYLES[status].label}
            </span>
          ))}
        </div>
      </div>

      <div className="relative h-[330px] overflow-hidden bg-background/35 sm:h-[370px]">
        <svg
          className="absolute inset-0 h-full w-full text-slate-300 dark:text-slate-600"
          viewBox="0 0 1000 360"
          preserveAspectRatio="xMidYMid meet"
          aria-label="Site locations"
        >
          <defs>
            <pattern id="site-map-dots" width="14" height="14" patternUnits="userSpaceOnUse">
              <circle cx="3" cy="3" r="2.2" fill="currentColor" />
            </pattern>
          </defs>
          <g fill="url(#site-map-dots)" opacity="0.8" aria-hidden="true">
            <path d="M87 92 135 54l94 4 66 37 40 49-27 35-55 7-23 35-49-17-32-45-44-20z" />
            <path d="m253 207 45 15 28 45-13 76-28 11-31-62-18-51z" />
            <path d="m424 75 36-17 35 10-4 21-56 10z" />
            <path d="m459 111 65-13 48 31 6 62-31 98-38 35-34-57 15-56-37-51z" />
            <path d="m515 79 79-31 156 9 104 51-24 48-81 14-63-34-64 21-55-28z" />
            <path d="m789 242 56-19 55 31-9 49-65 13-43-31z" />
            <path d="m158 35 45-25 43 14-24 24-56 6z" />
          </g>

          {mappedSites.map((site) => {
            const members = siteMembers(site.id, agents);
            const status = displayStatus(site, members, agentsKnown);
            const x = ((site.longitude! + 180) / 360) * 1000;
            const y = ((90 - site.latitude!) / 180) * 360;
            const labelWidth = Math.max(74, site.name.length * 8 + 20);
            const labelTop = y > 320 ? -38 : 13;
            const editable = canManage(site);
            const edit = () => editable && onEdit(site);
            return (
              <g
                key={site.id}
                transform={`translate(${x} ${y})`}
                className={cn(editable ? "cursor-pointer" : "cursor-default")}
                role={editable ? "button" : undefined}
                tabIndex={editable ? 0 : undefined}
                aria-label={`${site.name}, ${STATUS_STYLES[status].label}${
                  editable ? ", edit site" : ""
                }`}
                onClick={edit}
                onKeyDown={(event) => {
                  if (editable && (event.key === "Enter" || event.key === " ")) {
                    event.preventDefault();
                    edit();
                  }
                }}
              >
                <circle
                  r="8"
                  fill={STATUS_STYLES[status].dot}
                  stroke="var(--card)"
                  strokeWidth="3"
                  className="drop-shadow-sm transition-transform"
                />
                <rect
                  x={-labelWidth / 2}
                  y={labelTop}
                  width={labelWidth}
                  height="23"
                  rx="5"
                  fill="var(--card)"
                  fillOpacity="0.9"
                  stroke="var(--border)"
                  strokeWidth="0.7"
                />
                <text
                  x="0"
                  y={labelTop + 16}
                  textAnchor="middle"
                  fill="var(--foreground)"
                  className="font-mono text-[11px] font-semibold"
                >
                  {site.name}
                </text>
              </g>
            );
          })}
        </svg>

        {mappedSites.length === 0 && (
          <div className="absolute inset-0 flex items-center justify-center px-6 text-center">
            <div>
              <div className="text-[13.5px] font-semibold">No mapped sites yet</div>
              <div className="mt-1 max-w-sm font-mono text-[11.5px] text-muted-foreground">
                Add latitude and longitude when editing a site to place it on the
                footprint.
              </div>
            </div>
          </div>
        )}

        {mappedSites.length > 0 && mappedSites.length < sites.length && (
          <div className="absolute bottom-3 right-4 rounded-md bg-card/90 px-2 py-1 font-mono text-[10.5px] text-muted-foreground shadow-sm">
            {sites.length - mappedSites.length} without coordinates
          </div>
        )}
      </div>
    </section>
  );
}

export default function SitesPage() {
  const queryClient = useQueryClient();
  const { currentOrg } = useOrganization();
  const sitesQuery = useSites();
  const agentsQuery = useAgents();
  const vmsQuery = useVMs();
  const sites = useMemo(() => sitesQuery.data ?? [], [sitesQuery.data]);
  const agents = useMemo(() => agentsQuery.data ?? [], [agentsQuery.data]);
  const vms = useMemo(() => vmsQuery.data ?? [], [vmsQuery.data]);
  const agentsKnown = agentsQuery.data !== undefined;
  const vmsKnown = vmsQuery.data !== undefined;
  const agentsForbidden = isAgentsForbidden(agentsQuery.error);
  const { permissions } = usePermissions([
    ...(currentOrg
      ? [
          {
            key: "create",
            action: "agent:manage",
            node: { type: "organization" as const, id: currentOrg.id },
          },
        ]
      : []),
    ...sites.map((site) => ({
      key: `manage:${site.id}`,
      action: "site:manage",
      node: { type: "site" as const, id: site.id },
    })),
  ]);

  const [statusFilter, setStatusFilter] = useState<StatusFilter>("all");
  const filteredByStatus = useMemo(
    () =>
      statusFilter === "all"
        ? sites
        : sites.filter(
            (site) =>
              displayStatus(site, siteMembers(site.id, agents), agentsKnown) ===
              statusFilter
          ),
    [agents, agentsKnown, sites, statusFilter]
  );
  const list = useResourceList(
    filteredByStatus,
    (site) =>
      `${site.name} ${site.description ?? ""} ${site.regionCode ?? ""} ${
        site.locationLabel ?? ""
      } ${site.status}`
  );

  const [dialogOpen, setDialogOpen] = useState(false);
  const [editingSite, setEditingSite] = useState<Site | null>(null);
  const [form, setForm] = useState<SiteFormState>(EMPTY_FORM);

  const invalidate = () => queryClient.invalidateQueries({ queryKey: ["sites"] });

  const closeDialog = () => {
    setDialogOpen(false);
    setEditingSite(null);
    setForm(EMPTY_FORM);
  };

  const openCreate = () => {
    setEditingSite(null);
    setForm(EMPTY_FORM);
    setDialogOpen(true);
  };

  const openEdit = (site: Site) => {
    setEditingSite(site);
    setForm({
      name: site.name,
      description: site.description ?? "",
      status: site.status,
      regionCode: site.regionCode ?? "",
      locationLabel: site.locationLabel ?? "",
      latitude: site.latitude?.toString() ?? "",
      longitude: site.longitude?.toString() ?? "",
      labels: Object.entries(site.labels ?? {}).map(([key, value]) => ({
        key,
        value,
      })),
      networkControllerAgentId: site.networkControllerAgentId ?? "",
    });
    setDialogOpen(true);
  };

  const createSite = useMutation({
    mutationFn: sitesApi.create,
    onSuccess: () => {
      void invalidate();
      closeDialog();
      toast.success("Site created");
    },
    onError: (error) =>
      toast.error(error instanceof Error ? error.message : "Failed to create site"),
  });

  const updateSite = useMutation({
    mutationFn: ({ id, data }: { id: string; data: UpdateSiteRequest }) =>
      sitesApi.update(id, data),
    onSuccess: () => {
      void invalidate();
      closeDialog();
      toast.success("Site updated");
    },
    onError: (error) =>
      toast.error(error instanceof Error ? error.message : "Failed to update site"),
  });

  const deleteSite = useMutation({
    mutationFn: sitesApi.delete,
    onSuccess: () => {
      void invalidate();
      toast.success("Site deleted");
    },
    onError: (error) =>
      toast.error(error instanceof Error ? error.message : "Failed to delete site"),
  });

  const handleDelete = (site: Site) => {
    if (
      window.confirm(
        `Delete site "${site.name}"? This cannot be undone, and sites with agents cannot be deleted.`
      )
    ) {
      deleteSite.mutate(site.id);
    }
  };

  const handleSubmit = (event: FormEvent) => {
    event.preventDefault();
    if (!form.name.trim()) {
      toast.error("Please enter a site name");
      return;
    }
    if (!editingSite && !currentOrg) {
      toast.error("Select an organization before creating a site");
      return;
    }

    const latitude = form.latitude.trim() ? Number(form.latitude) : undefined;
    const longitude = form.longitude.trim() ? Number(form.longitude) : undefined;
    if ((latitude === undefined) !== (longitude === undefined)) {
      toast.error("Provide both latitude and longitude, or neither");
      return;
    }
    if (
      (latitude !== undefined &&
        (Number.isNaN(latitude) || latitude < -90 || latitude > 90)) ||
      (longitude !== undefined &&
        (Number.isNaN(longitude) || longitude < -180 || longitude > 180))
    ) {
      toast.error("Latitude must be -90 to 90 and longitude must be -180 to 180");
      return;
    }

    const populatedLabels = form.labels.filter(
      ({ key, value }) => key !== "" || value !== ""
    );
    if (populatedLabels.some(({ key }) => key === "")) {
      toast.error("Every label value needs a key");
      return;
    }
    const labelKeys = populatedLabels.map(({ key }) => key);
    if (new Set(labelKeys).size !== labelKeys.length) {
      toast.error("Label keys must be unique");
      return;
    }
    const labels = Object.fromEntries(
      populatedLabels.map(({ key, value }) => [key, value])
    );
    const details = {
      description: form.description.trim() || undefined,
      status: form.status,
      regionCode: form.regionCode.trim() || undefined,
      locationLabel: form.locationLabel.trim() || undefined,
      latitude,
      longitude,
      labels,
    };

    if (editingSite) {
      updateSite.mutate({
        id: editingSite.id,
        data: {
          ...details,
          networkControllerAgentId:
            form.networkControllerAgentId || editingSite.networkControllerAgentId,
        },
      });
    } else {
      createSite.mutate({
        name: form.name.trim(),
        organizationId: currentOrg!.id,
        ...details,
      });
    }
  };

  const stats = useMemo(() => {
    const onlineAgents = agents.filter((agent) => agent.isOnline);
    const totalCPU = onlineAgents.reduce(
      (sum, agent) => sum + agent.resources.totalCPU,
      0
    );
    const availableCPU = onlineAgents.reduce(
      (sum, agent) => sum + agent.resources.availableCPU,
      0
    );
    const provisioning = sites.filter(
      (site) =>
        displayStatus(site, siteMembers(site.id, agents), agentsKnown) ===
        "provisioning"
    ).length;
    const usableControllers = sites.filter(
      (site) =>
        !!site.networkControllerAgentId &&
        !site.networkControllerIssue &&
        (!site.networkControllerStatus || site.networkControllerStatus === "online")
    ).length;
    return {
      onlineAgents,
      provisioning,
      live: sites.length - provisioning,
      fleetCapacity: reservedPercent(totalCPU, availableCPU),
      runningVMs: vms.filter((vm) => vm.status === "Running").length,
      controllerCoverage:
        sites.length === 0 ? 0 : Math.round((usableControllers / sites.length) * 100),
      usableControllers,
    };
  }, [agents, agentsKnown, sites, vms]);

  const loading = sitesQuery.isLoading || (agentsQuery.isLoading && !agentsForbidden);
  const mutationPending = createSite.isPending || updateSite.isPending;
  const editableAgents = editingSite
    ? agents.filter(
        (agent) =>
          agent.siteId === editingSite.id && agent.networkCapability === "overlay"
      )
    : [];
  const currentControllerMissing =
    editingSite?.networkControllerAgentId &&
    !editableAgents.some((agent) => agent.id === editingSite.networkControllerAgentId);

  return (
    <div className="mx-auto max-w-[1360px] space-y-3.5">
      <header className="mb-4 flex flex-col gap-3 sm:flex-row sm:items-center">
        <div>
          <h1 className="text-[22px] font-bold tracking-tight">Sites</h1>
          <div className="mt-0.5 font-mono text-[12.5px] text-muted-foreground">
            availability zones
            {agentsKnown &&
              ` · ${stats.live} live · ${stats.provisioning} provisioning`}
          </div>
        </div>
        <div className="flex-1" />
        {permissions.create && (
          <Button
            onClick={openCreate}
            className="h-[34px] rounded-lg px-4 text-[12.5px] font-semibold"
          >
            <Plus className="h-3.5 w-3.5" strokeWidth={2.2} />
            New site
          </Button>
        )}
      </header>

      <QueryErrorNotice
        resource="sites"
        error={
          sitesQuery.error ??
          vmsQuery.error ??
          (agentsForbidden ? null : agentsQuery.error)
        }
        hasData={sitesQuery.data !== undefined}
        onRetry={() => {
          void sitesQuery.refetch();
          void vmsQuery.refetch();
          if (!agentsForbidden) void agentsQuery.refetch();
        }}
      />

      {sitesQuery.isLoading ? (
        <Skeleton className="h-[425px] rounded-[11px]" />
      ) : (
        <SiteFootprint
          sites={sites}
          agents={agents}
          agentsKnown={agentsKnown}
          canManage={(site) => !!permissions[`manage:${site.id}`]}
          onEdit={openEdit}
        />
      )}

      {loading ? (
        <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-5">
          {Array.from({ length: 5 }).map((_, index) => (
            <Skeleton key={index} className="h-[104px] rounded-[11px]" />
          ))}
        </div>
      ) : (
        <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-5">
          <KpiCard
            label="Sites"
            value={String(sites.length)}
            sub={
              agentsKnown
                ? `${stats.live} live · ${stats.provisioning} provisioning`
                : "fleet status unavailable"
            }
          />
          <KpiCard
            label="Fleet capacity"
            value={agentsKnown ? String(stats.fleetCapacity) : "—"}
            unit={agentsKnown ? "%" : undefined}
            sub={agentsKnown ? "vCPU reserved" : "agent data unavailable"}
          />
          <KpiCard
            label="Agents online"
            value={agentsKnown ? String(stats.onlineAgents.length) : "—"}
            unit={agentsKnown ? `/${agents.length}` : undefined}
            sub={
              agentsKnown && agents.length > 0 && stats.onlineAgents.length === agents.length
                ? "all reporting"
                : agentsKnown
                  ? `${agents.length - stats.onlineAgents.length} unavailable`
                  : "requires fleet access"
            }
            tone={
              agentsKnown && agents.length > stats.onlineAgents.length
                ? "negative"
                : agentsKnown && agents.length > 0
                  ? "positive"
                  : "neutral"
            }
          />
          <KpiCard
            label="Instances"
            value={vmsKnown ? String(vms.length) : "—"}
            sub={vmsKnown ? `${stats.runningVMs} running` : "instance data unavailable"}
          />
          <KpiCard
            label="Controller coverage"
            value={String(stats.controllerCoverage)}
            unit="%"
            sub={`${stats.usableControllers} of ${sites.length} usable`}
            tone={
              sites.length > 0 && stats.usableControllers < sites.length
                ? "warning"
                : sites.length > 0
                  ? "positive"
                  : "neutral"
            }
          />
        </div>
      )}

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

        {sitesQuery.isLoading ? (
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
            {permissions.create && (
              <Button size="sm" className="mt-4" onClick={openCreate}>
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
                      {permissions[`manage:${site.id}`] && (
                        <DropdownMenu>
                          <DropdownMenuTrigger asChild>
                            <Button variant="ghost" size="icon-sm" aria-label={`Actions for ${site.name}`} disabled={deleteSite.isPending && deleteSite.variables === site.id}>
                              <MoreHorizontal className="h-4 w-4" />
                            </Button>
                          </DropdownMenuTrigger>
                          <DropdownMenuContent align="end">
                            <DropdownMenuItem onClick={() => openEdit(site)}>
                              <Pencil className="mr-2 h-4 w-4" />Edit site
                            </DropdownMenuItem>
                            <DropdownMenuSeparator />
                            <DropdownMenuItem variant="destructive" onClick={() => handleDelete(site)}>
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

      <Dialog open={dialogOpen} onOpenChange={(open) => (open ? setDialogOpen(true) : closeDialog())}>
        <DialogContent className="max-h-[90vh] overflow-y-auto bg-card sm:max-w-[620px]">
          <DialogHeader>
            <DialogTitle>{editingSite ? `Edit ${editingSite.name}` : "New site"}</DialogTitle>
            <DialogDescription>
              {editingSite
                ? "Update this availability zone. Changes affect where agents and site-pinned networks operate."
                : `Create an availability zone${currentOrg ? ` in ${currentOrg.name}` : ""} for agents that share one network fabric.`}
            </DialogDescription>
          </DialogHeader>
          <form onSubmit={handleSubmit}>
            <div className="space-y-4 py-4">
              <div className="space-y-2">
                <Label htmlFor="site-name">Name</Label>
                <Input id="site-name" placeholder="us-east-1" value={form.name} onChange={(event) => setForm((current) => ({ ...current, name: event.target.value }))} disabled={mutationPending || !!editingSite} />
                {editingSite && <p className="text-xs text-muted-foreground">Site names cannot be changed after creation.</p>}
              </div>
              <div className="space-y-2">
                <Label htmlFor="site-description">Description</Label>
                <Input id="site-description" placeholder="Primary east coast availability zone" value={form.description} onChange={(event) => setForm((current) => ({ ...current, description: event.target.value }))} disabled={mutationPending} />
              </div>
              <div className="grid gap-4 sm:grid-cols-2">
                <div className="space-y-2">
                  <Label htmlFor="site-status">Lifecycle</Label>
                  <Select value={form.status} onValueChange={(value) => setForm((current) => ({ ...current, status: value as SiteStatus }))} disabled={mutationPending}>
                    <SelectTrigger id="site-status"><SelectValue /></SelectTrigger>
                    <SelectContent>{SITE_STATUSES.map((status) => <SelectItem key={status} value={status}>{status}</SelectItem>)}</SelectContent>
                  </Select>
                </div>
                <div className="space-y-2">
                  <Label htmlFor="site-region">Region code</Label>
                  <Input id="site-region" placeholder="americas" value={form.regionCode} onChange={(event) => setForm((current) => ({ ...current, regionCode: event.target.value }))} disabled={mutationPending} />
                </div>
              </div>
              <div className="space-y-2">
                <Label htmlFor="site-location">Location label</Label>
                <Input id="site-location" placeholder="Ashburn, VA" value={form.locationLabel} onChange={(event) => setForm((current) => ({ ...current, locationLabel: event.target.value }))} disabled={mutationPending} />
              </div>
              <div className="grid gap-4 sm:grid-cols-2">
                <div className="space-y-2">
                  <Label htmlFor="site-latitude">Latitude</Label>
                  <Input id="site-latitude" type="number" step="any" min={-90} max={90} placeholder="38.9445" value={form.latitude} onChange={(event) => setForm((current) => ({ ...current, latitude: event.target.value }))} disabled={mutationPending} />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="site-longitude">Longitude</Label>
                  <Input id="site-longitude" type="number" step="any" min={-180} max={180} placeholder="-77.4558" value={form.longitude} onChange={(event) => setForm((current) => ({ ...current, longitude: event.target.value }))} disabled={mutationPending} />
                </div>
              </div>
              {editingSite && (
                <div className="space-y-2">
                  <Label htmlFor="site-controller">Network controller</Label>
                  <Select value={form.networkControllerAgentId || undefined} onValueChange={(value) => setForm((current) => ({ ...current, networkControllerAgentId: value }))} disabled={mutationPending || editableAgents.length === 0}>
                    <SelectTrigger id="site-controller"><SelectValue placeholder="No eligible agents" /></SelectTrigger>
                    <SelectContent>
                      {currentControllerMissing && editingSite.networkControllerAgentId && <SelectItem value={editingSite.networkControllerAgentId}>Current controller ({editingSite.networkControllerAgentId.slice(0, 8)}…)</SelectItem>}
                      {editableAgents.map((agent) => <SelectItem key={agent.id} value={agent.id}>{agent.name}</SelectItem>)}
                    </SelectContent>
                  </Select>
                  <p className="text-xs text-muted-foreground">Only overlay-network agents assigned to this site are eligible.</p>
                </div>
              )}
              <div className="space-y-2">
                <div className="flex items-center justify-between gap-3">
                  <Label>Labels</Label>
                  <Button
                    type="button"
                    variant="outline"
                    size="sm"
                    onClick={() =>
                      setForm((current) => ({
                        ...current,
                        labels: [...current.labels, { key: "", value: "" }],
                      }))
                    }
                    disabled={mutationPending}
                  >
                    <Plus className="h-3.5 w-3.5" />
                    Add label
                  </Button>
                </div>
                {form.labels.length === 0 ? (
                  <p className="rounded-md border border-dashed border-border px-3 py-4 text-center text-xs text-muted-foreground">
                    No labels configured.
                  </p>
                ) : (
                  <div className="space-y-2">
                    {form.labels.map((label, index) => (
                      <div
                        key={index}
                        className="grid grid-cols-[minmax(0,1fr)_minmax(0,1fr)_auto] gap-2"
                      >
                        <Input
                          aria-label={`Label ${index + 1} key`}
                          placeholder="Key"
                          value={label.key}
                          onChange={(event) =>
                            setForm((current) => ({
                              ...current,
                              labels: current.labels.map((item, itemIndex) =>
                                itemIndex === index
                                  ? { ...item, key: event.target.value }
                                  : item
                              ),
                            }))
                          }
                          disabled={mutationPending}
                        />
                        <Input
                          aria-label={`Label ${index + 1} value`}
                          placeholder="Value"
                          value={label.value}
                          onChange={(event) =>
                            setForm((current) => ({
                              ...current,
                              labels: current.labels.map((item, itemIndex) =>
                                itemIndex === index
                                  ? { ...item, value: event.target.value }
                                  : item
                              ),
                            }))
                          }
                          disabled={mutationPending}
                        />
                        <Button
                          type="button"
                          variant="ghost"
                          size="icon"
                          aria-label={`Remove label ${index + 1}`}
                          onClick={() =>
                            setForm((current) => ({
                              ...current,
                              labels: current.labels.filter(
                                (_, itemIndex) => itemIndex !== index
                              ),
                            }))
                          }
                          disabled={mutationPending}
                        >
                          <Trash2 className="h-4 w-4" />
                        </Button>
                      </div>
                    ))}
                  </div>
                )}
                <p className="text-xs text-muted-foreground">
                  Keys and values are saved exactly as entered.
                </p>
              </div>
            </div>
            <DialogFooter>
              <Button type="button" variant="outline" onClick={closeDialog} disabled={mutationPending}>Cancel</Button>
              <Button type="submit" disabled={mutationPending}>
                {mutationPending && <Loader2 className="h-4 w-4 animate-spin" />}
                {editingSite ? "Save changes" : "Create site"}
              </Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>
    </div>
  );
}
