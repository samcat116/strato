"use client";

import { useState } from "react";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { Loader2, Plus, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
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
import { toast } from "sonner";

export default function SitesPage() {
  const queryClient = useQueryClient();
  // Sites are listed and created in the org selected in the sidebar switcher.
  const { currentOrg } = useOrganization();
  const { data: agents = [] } = useAgents();
  const { data: sites = [], isLoading } = useSites();

  const [createOpen, setCreateOpen] = useState(false);
  const [name, setName] = useState("");
  const [description, setDescription] = useState("");

  const invalidate = () => queryClient.invalidateQueries({ queryKey: ["sites"] });

  const createSite = useMutation({
    mutationFn: sitesApi.create,
    onSuccess: () => {
      invalidate();
      setCreateOpen(false);
      setName("");
      setDescription("");
      toast.success("Site created");
    },
    onError: (error) =>
      toast.error(error instanceof Error ? error.message : "Failed to create site"),
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
    createSite.mutate({
      name: name.trim(),
      description: description.trim() || undefined,
      organizationId: currentOrg.id,
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
                  <TableHead className="text-muted-foreground font-medium">Agents</TableHead>
                  <TableHead className="text-muted-foreground font-medium">
                    Network Controller
                  </TableHead>
                  <TableHead className="text-muted-foreground font-medium w-12" />
                </TableRow>
              </TableHeader>
              <TableBody className="divide-y divide-border">
                {sites.map((site) => (
                  <TableRow key={site.id} className="border-border hover:bg-accent/60">
                    <TableCell>
                      <span className="font-medium text-foreground">{site.name}</span>
                      {site.description && (
                        <p className="text-sm text-muted-foreground">{site.description}</p>
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
                ))}
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
