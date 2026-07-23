"use client";

import { useState } from "react";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { Loader2, Plus, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { Skeleton } from "@/components/ui/skeleton";
import { sitesApi } from "@/lib/api/sites";
import { useAgents, useSites } from "@/lib/hooks";
import { useOrganization } from "@/providers";
import type { Site, SiteStatus } from "@/types/api";
import { toast } from "sonner";

const SITE_STATUSES: SiteStatus[] = [
  "active",
  "draining",
  "maintenance",
  "decommissioned",
];

const statusBadgeVariant = (
  status: SiteStatus
): "default" | "secondary" | "outline" => {
  switch (status) {
    case "active":
      return "default";
    case "decommissioned":
      return "outline";
    default:
      return "secondary";
  }
};

/** Parse a `key=value, key2=value2` string into a labels map (blank → {}). */
const parseLabels = (input: string): Record<string, string> => {
  const labels: Record<string, string> = {};
  for (const pair of input.split(",")) {
    const trimmed = pair.trim();
    if (!trimmed) continue;
    const eq = trimmed.indexOf("=");
    if (eq === -1) continue;
    const key = trimmed.slice(0, eq).trim();
    const value = trimmed.slice(eq + 1).trim();
    if (key) labels[key] = value;
  }
  return labels;
};

export default function SitesPage() {
  const queryClient = useQueryClient();
  // Sites are listed and created in the org selected in the sidebar switcher.
  const { currentOrg } = useOrganization();
  const { data: agents = [] } = useAgents();
  const { data: sites = [], isLoading } = useSites();

  const [createOpen, setCreateOpen] = useState(false);
  const [name, setName] = useState("");
  const [description, setDescription] = useState("");
  const [status, setStatus] = useState<SiteStatus>("active");
  const [regionCode, setRegionCode] = useState("");
  const [locationLabel, setLocationLabel] = useState("");
  const [latitude, setLatitude] = useState("");
  const [longitude, setLongitude] = useState("");
  const [labelsInput, setLabelsInput] = useState("");

  const invalidate = () => queryClient.invalidateQueries({ queryKey: ["sites"] });

  const resetForm = () => {
    setName("");
    setDescription("");
    setStatus("active");
    setRegionCode("");
    setLocationLabel("");
    setLatitude("");
    setLongitude("");
    setLabelsInput("");
  };

  const createSite = useMutation({
    mutationFn: sitesApi.create,
    onSuccess: () => {
      invalidate();
      setCreateOpen(false);
      resetForm();
      toast.success("Site created");
    },
    onError: (error) =>
      toast.error(error instanceof Error ? error.message : "Failed to create site"),
  });

  // Changing lifecycle is a full-replace PUT, so echo the site's other
  // descriptive fields to preserve them and send only the new status.
  const updateStatus = useMutation({
    mutationFn: ({ site, next }: { site: Site; next: SiteStatus }) =>
      sitesApi.update(site.id, {
        description: site.description,
        networkControllerAgentId: site.networkControllerAgentId,
        status: next,
        latitude: site.latitude,
        longitude: site.longitude,
        locationLabel: site.locationLabel,
        regionCode: site.regionCode,
        labels: site.labels,
      }),
    onSuccess: () => {
      invalidate();
      toast.success("Site status updated");
    },
    onError: (error) =>
      toast.error(error instanceof Error ? error.message : "Failed to update site"),
  });

  const deleteSite = useMutation({
    mutationFn: sitesApi.delete,
    onSuccess: () => {
      invalidate();
      toast.success("Site deleted");
    },
    onError: (error) =>
      toast.error(error instanceof Error ? error.message : "Failed to delete site"),
  });

  const controllerName = (id?: string) =>
    id ? (agents.find((a) => a.id === id)?.name ?? `${id.slice(0, 8)}…`) : "None";

  const memberCount = (siteId: string) => agents.filter((a) => a.siteId === siteId).length;

  const locationSummary = (site: Site) => {
    const parts: string[] = [];
    if (site.locationLabel) parts.push(site.locationLabel);
    if (
      typeof site.latitude === "number" &&
      typeof site.longitude === "number"
    ) {
      parts.push(`${site.latitude.toFixed(4)}, ${site.longitude.toFixed(4)}`);
    }
    return parts;
  };

  const handleCreate = (e: React.FormEvent) => {
    e.preventDefault();
    if (!name.trim()) {
      toast.error("Please enter a site name");
      return;
    }
    if (!currentOrg) {
      toast.error("Select an organization before creating a site");
      return;
    }
    const lat = latitude.trim() ? Number(latitude) : undefined;
    const lon = longitude.trim() ? Number(longitude) : undefined;
    if ((lat === undefined) !== (lon === undefined)) {
      toast.error("Provide both latitude and longitude, or neither");
      return;
    }
    if (
      (lat !== undefined && Number.isNaN(lat)) ||
      (lon !== undefined && Number.isNaN(lon))
    ) {
      toast.error("Latitude and longitude must be numbers");
      return;
    }
    const labels = parseLabels(labelsInput);
    createSite.mutate({
      name: name.trim(),
      description: description.trim() || undefined,
      organizationId: currentOrg.id,
      status,
      regionCode: regionCode.trim() || undefined,
      locationLabel: locationLabel.trim() || undefined,
      latitude: lat,
      longitude: lon,
      labels: Object.keys(labels).length ? labels : undefined,
    });
  };

  return (
    <div className="max-w-7xl mx-auto space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-2xl font-semibold text-foreground">Sites</h2>
          <p className="text-muted-foreground">
            Availability zones — groups of agents sharing one network fabric
          </p>
        </div>
        <Button
          className="bg-primary hover:bg-primary/90"
          onClick={() => setCreateOpen(true)}
        >
          <Plus className="h-4 w-4 mr-2" />
          Add Site
        </Button>
      </div>

      <Card className="bg-card border-border">
        <CardHeader>
          <CardTitle className="text-lg font-semibold text-foreground">
            Registered Sites
          </CardTitle>
        </CardHeader>
        <CardContent>
          {isLoading ? (
            <div className="space-y-2">
              {[...Array(3)].map((_, i) => (
                <Skeleton key={i} className="h-12 w-full bg-muted" />
              ))}
            </div>
          ) : sites.length === 0 ? (
            <div className="text-center py-8 text-muted-foreground">
              No sites yet. A site groups agents that share one OVN deployment;
              networks pinned to a site span its nodes.
            </div>
          ) : (
            <Table>
              <TableHeader className="bg-background">
                <TableRow className="border-border hover:bg-transparent">
                  <TableHead className="text-muted-foreground font-medium">Name</TableHead>
                  <TableHead className="text-muted-foreground font-medium">Status</TableHead>
                  <TableHead className="text-muted-foreground font-medium">Location</TableHead>
                  <TableHead className="text-muted-foreground font-medium">Labels</TableHead>
                  <TableHead className="text-muted-foreground font-medium">Agents</TableHead>
                  <TableHead className="text-muted-foreground font-medium">
                    Network Controller
                  </TableHead>
                  <TableHead className="text-muted-foreground font-medium w-12" />
                </TableRow>
              </TableHeader>
              <TableBody className="divide-y divide-border">
                {sites.map((site) => {
                  const location = locationSummary(site);
                  const labelEntries = Object.entries(site.labels ?? {});
                  return (
                    <TableRow key={site.id} className="border-border hover:bg-accent/60">
                      <TableCell>
                        <span className="font-medium text-foreground">{site.name}</span>
                        {site.regionCode && (
                          <span className="ml-2 font-mono text-xs text-muted-foreground">
                            {site.regionCode}
                          </span>
                        )}
                        {site.description && (
                          <p className="text-sm text-muted-foreground">{site.description}</p>
                        )}
                      </TableCell>
                      <TableCell>
                        <Select
                          value={site.status}
                          onValueChange={(next) =>
                            updateStatus.mutate({ site, next: next as SiteStatus })
                          }
                          disabled={updateStatus.isPending}
                        >
                          <SelectTrigger className="h-8 w-[150px] border-border bg-background">
                            <SelectValue>
                              <Badge variant={statusBadgeVariant(site.status)}>
                                {site.status}
                              </Badge>
                            </SelectValue>
                          </SelectTrigger>
                          <SelectContent>
                            {SITE_STATUSES.map((s) => (
                              <SelectItem key={s} value={s}>
                                {s}
                              </SelectItem>
                            ))}
                          </SelectContent>
                        </Select>
                      </TableCell>
                      <TableCell className="text-foreground/80">
                        {location.length ? (
                          <div className="text-sm">
                            {location.map((part, i) => (
                              <div
                                key={i}
                                className={i === 0 ? "" : "text-xs text-muted-foreground"}
                              >
                                {part}
                              </div>
                            ))}
                          </div>
                        ) : (
                          <span className="text-muted-foreground">—</span>
                        )}
                      </TableCell>
                      <TableCell>
                        {labelEntries.length ? (
                          <div className="flex flex-wrap gap-1">
                            {labelEntries.map(([k, v]) => (
                              <Badge key={k} variant="outline" className="font-mono text-xs">
                                {k}={v}
                              </Badge>
                            ))}
                          </div>
                        ) : (
                          <span className="text-muted-foreground">—</span>
                        )}
                      </TableCell>
                      <TableCell className="text-foreground/80">
                        {memberCount(site.id)}
                      </TableCell>
                      <TableCell className="text-foreground/80">
                        {controllerName(site.networkControllerAgentId)}
                      </TableCell>
                      <TableCell>
                        <Button
                          size="sm"
                          variant="ghost"
                          className="text-muted-foreground hover:text-red-600"
                          onClick={() => deleteSite.mutate(site.id)}
                          disabled={deleteSite.isPending}
                        >
                          <Trash2 className="h-4 w-4" />
                        </Button>
                      </TableCell>
                    </TableRow>
                  );
                })}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>

      <Dialog open={createOpen} onOpenChange={setCreateOpen}>
        <DialogContent className="bg-card border-border text-foreground">
          <DialogHeader>
            <DialogTitle>Add Site</DialogTitle>
            <DialogDescription className="text-muted-foreground">
              A site is an availability zone: agents in it share one OVN
              deployment, so networks pinned to the site span its nodes.
              {currentOrg
                ? ` The site is created in ${currentOrg.name}, and all its agents must belong to that organization.`
                : ""}
            </DialogDescription>
          </DialogHeader>
          <form onSubmit={handleCreate}>
            <div className="space-y-4 py-4">
              <div className="space-y-2">
                <Label htmlFor="siteName" className="text-foreground">
                  Name
                </Label>
                <Input
                  id="siteName"
                  placeholder="dc-east-1"
                  value={name}
                  onChange={(e) => setName(e.target.value)}
                  className="bg-background border-border text-foreground"
                  disabled={createSite.isPending}
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="siteDescription" className="text-foreground">
                  Description (optional)
                </Label>
                <Input
                  id="siteDescription"
                  value={description}
                  onChange={(e) => setDescription(e.target.value)}
                  className="bg-background border-border text-foreground"
                  disabled={createSite.isPending}
                />
              </div>
              <div className="grid grid-cols-2 gap-4">
                <div className="space-y-2">
                  <Label htmlFor="siteStatus" className="text-foreground">
                    Status
                  </Label>
                  <Select
                    value={status}
                    onValueChange={(v) => setStatus(v as SiteStatus)}
                    disabled={createSite.isPending}
                  >
                    <SelectTrigger
                      id="siteStatus"
                      className="bg-background border-border text-foreground"
                    >
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent>
                      {SITE_STATUSES.map((s) => (
                        <SelectItem key={s} value={s}>
                          {s}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>
                <div className="space-y-2">
                  <Label htmlFor="siteRegion" className="text-foreground">
                    Region code (optional)
                  </Label>
                  <Input
                    id="siteRegion"
                    placeholder="us-east-1"
                    value={regionCode}
                    onChange={(e) => setRegionCode(e.target.value)}
                    className="bg-background border-border text-foreground"
                    disabled={createSite.isPending}
                  />
                </div>
              </div>
              <div className="space-y-2">
                <Label htmlFor="siteLocation" className="text-foreground">
                  Location label (optional)
                </Label>
                <Input
                  id="siteLocation"
                  placeholder="Equinix DC1, Ashburn VA"
                  value={locationLabel}
                  onChange={(e) => setLocationLabel(e.target.value)}
                  className="bg-background border-border text-foreground"
                  disabled={createSite.isPending}
                />
              </div>
              <div className="grid grid-cols-2 gap-4">
                <div className="space-y-2">
                  <Label htmlFor="siteLat" className="text-foreground">
                    Latitude (optional)
                  </Label>
                  <Input
                    id="siteLat"
                    type="number"
                    step="any"
                    placeholder="38.9445"
                    value={latitude}
                    onChange={(e) => setLatitude(e.target.value)}
                    className="bg-background border-border text-foreground"
                    disabled={createSite.isPending}
                  />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="siteLon" className="text-foreground">
                    Longitude (optional)
                  </Label>
                  <Input
                    id="siteLon"
                    type="number"
                    step="any"
                    placeholder="-77.4558"
                    value={longitude}
                    onChange={(e) => setLongitude(e.target.value)}
                    className="bg-background border-border text-foreground"
                    disabled={createSite.isPending}
                  />
                </div>
              </div>
              <div className="space-y-2">
                <Label htmlFor="siteLabels" className="text-foreground">
                  Labels (optional)
                </Label>
                <Input
                  id="siteLabels"
                  placeholder="tier=production, provider=equinix"
                  value={labelsInput}
                  onChange={(e) => setLabelsInput(e.target.value)}
                  className="bg-background border-border text-foreground"
                  disabled={createSite.isPending}
                />
                <p className="text-xs text-muted-foreground">
                  Comma-separated key=value pairs.
                </p>
              </div>
            </div>
            <DialogFooter>
              <Button
                type="button"
                variant="outline"
                onClick={() => setCreateOpen(false)}
                className="border-input text-foreground/80 hover:bg-accent"
                disabled={createSite.isPending}
              >
                Cancel
              </Button>
              <Button
                type="submit"
                className="bg-primary hover:bg-primary/90"
                disabled={createSite.isPending}
              >
                {createSite.isPending ? (
                  <>
                    <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                    Creating...
                  </>
                ) : (
                  "Create Site"
                )}
              </Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>
    </div>
  );
}
