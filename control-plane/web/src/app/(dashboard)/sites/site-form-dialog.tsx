"use client";

import type { Dispatch, FormEventHandler, SetStateAction } from "react";
import { Loader2, Plus, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
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
import type { Agent, Site, SiteStatus } from "@/types/api";
import { SITE_STATUSES, type SiteFormState } from "./site-model";

interface SiteFormDialogProps {
  open: boolean;
  onOpen: () => void;
  onClose: () => void;
  editingSite: Site | null;
  organizationName?: string;
  form: SiteFormState;
  setForm: Dispatch<SetStateAction<SiteFormState>>;
  mutationPending: boolean;
  editableAgents: Agent[];
  currentControllerMissing: boolean;
  onSubmit: FormEventHandler<HTMLFormElement>;
}

export function SiteFormDialog({
  open,
  onOpen,
  onClose,
  editingSite,
  organizationName,
  form,
  setForm,
  mutationPending,
  editableAgents,
  currentControllerMissing,
  onSubmit,
}: SiteFormDialogProps) {
  return (
    <Dialog open={open} onOpenChange={(nextOpen) => (nextOpen ? onOpen() : onClose())}>
      <DialogContent className="max-h-[90vh] overflow-y-auto bg-card sm:max-w-[620px]">
        <DialogHeader>
          <DialogTitle>{editingSite ? `Edit ${editingSite.name}` : "New site"}</DialogTitle>
          <DialogDescription>
            {editingSite
              ? "Update this availability zone. Changes affect where agents and site-pinned networks operate."
              : `Create an availability zone${organizationName ? ` in ${organizationName}` : ""} for agents that share one network fabric.`}
          </DialogDescription>
        </DialogHeader>
        <form onSubmit={onSubmit}>
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
            <Button type="button" variant="outline" onClick={onClose} disabled={mutationPending}>Cancel</Button>
            <Button type="submit" disabled={mutationPending}>
              {mutationPending && <Loader2 className="h-4 w-4 animate-spin" />}
              {editingSite ? "Save changes" : "Create site"}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
