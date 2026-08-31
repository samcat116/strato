"use client";

import { confirmAction } from "@/providers/confirmation-provider";

import { useMemo, useState, type FormEvent } from "react";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { Plus } from "lucide-react";
import { toast } from "sonner";
import { KpiCard, reservedPercent } from "@/components/overview";
import { Button } from "@/components/ui/button";
import { QueryErrorNotice } from "@/components/ui/query-error-notice";
import { useResourceList } from "@/components/ui/resource-list-controls";
import { Skeleton } from "@/components/ui/skeleton";
import { sitesApi } from "@/lib/api/sites";
import {
  isAgentsForbidden,
  useAgents,
  usePermissions,
  useSites,
  useVMs,
} from "@/lib/hooks";
import { useOrganization } from "@/providers";
import type { Site, UpdateSiteRequest } from "@/types/api";
import { SiteFootprint } from "./site-footprint";
import { SiteFormDialog } from "./site-form-dialog";
import { SitesTable } from "./sites-table";
import {
  EMPTY_FORM,
  displayStatus,
  siteMembers,
  type SiteFormState,
  type StatusFilter,
} from "./site-model";

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

  const handleDelete = async (site: Site) => {
    if (
      await confirmAction(
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
      live: sites.filter((site) => site.status === "active").length,
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

      <SitesTable
        sites={sites}
        isLoading={sitesQuery.isLoading}
        agents={agents}
        vms={vms}
        agentsKnown={agentsKnown}
        vmsKnown={vmsKnown}
        list={list}
        statusFilter={statusFilter}
        setStatusFilter={setStatusFilter}
        canCreate={!!permissions.create}
        canManage={(site) => !!permissions[`manage:${site.id}`]}
        deletePending={deleteSite.isPending}
        deletingSiteId={deleteSite.variables}
        onCreate={openCreate}
        onEdit={openEdit}
        onDelete={handleDelete}
      />

      <SiteFormDialog
        open={dialogOpen}
        onOpen={() => setDialogOpen(true)}
        onClose={closeDialog}
        editingSite={editingSite}
        organizationName={currentOrg?.name}
        form={form}
        setForm={setForm}
        mutationPending={mutationPending}
        editableAgents={editableAgents}
        currentControllerMissing={!!currentControllerMissing}
        onSubmit={handleSubmit}
      />
    </div>
  );
}
