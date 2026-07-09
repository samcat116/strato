"use client";

import { useState } from "react";
import { Loader2 } from "lucide-react";
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
import { networksApi } from "@/lib/api/networks";
import { useProjectContext } from "@/providers";
import { toast } from "sonner";
import {
  DHCPFields,
  emptyDhcpForm,
  parseDhcpForm,
  type DhcpFormState,
} from "./dhcp-fields";

interface CreateNetworkDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onCreated?: () => void;
}

// A loose sanity check; the server is the source of truth for CIDR validity.
const CIDR_PATTERN = /^(\d{1,3}\.){3}\d{1,3}\/\d{1,2}$/;

export function CreateNetworkDialog({
  open,
  onOpenChange,
  onCreated,
}: CreateNetworkDialogProps) {
  const [isLoading, setIsLoading] = useState(false);
  const [formData, setFormData] = useState({
    name: "",
    subnet: "",
    gateway: "",
  });
  const [dhcp, setDhcp] = useState<DhcpFormState>(emptyDhcpForm);

  // The network is created in the project selected in the header switcher.
  const { currentProject } = useProjectContext();
  const projectId = currentProject?.id;

  const resetForm = () => {
    setFormData({ name: "", subnet: "", gateway: "" });
    setDhcp(emptyDhcpForm);
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    const name = formData.name.trim();
    if (!name) {
      toast.error("Please enter a network name");
      return;
    }

    const subnet = formData.subnet.trim();
    if (!CIDR_PATTERN.test(subnet)) {
      toast.error("Subnet must be in CIDR notation, e.g. 10.0.0.0/24");
      return;
    }

    setIsLoading(true);
    try {
      await networksApi.create({
        name,
        subnet,
        gateway: formData.gateway.trim() || undefined,
        projectId,
        ...parseDhcpForm(dhcp),
      });
      toast.success(`Network "${name}" created`);
      onOpenChange(false);
      onCreated?.();
      resetForm();
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : "Failed to create network"
      );
    } finally {
      setIsLoading(false);
    }
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="bg-card border-border text-foreground">
        <DialogHeader>
          <DialogTitle>Create Network</DialogTitle>
          <DialogDescription className="text-muted-foreground">
            {currentProject
              ? `Create a new network in ${currentProject.name}`
              : "Create a new network"}
          </DialogDescription>
        </DialogHeader>
        <form onSubmit={handleSubmit}>
          <div className="space-y-4 py-4">
            <div className="space-y-2">
              <Label htmlFor="networkName" className="text-foreground">
                Name
              </Label>
              <Input
                id="networkName"
                placeholder="app-net"
                value={formData.name}
                onChange={(e) =>
                  setFormData({ ...formData, name: e.target.value })
                }
                className="bg-background border-border text-foreground"
                disabled={isLoading}
                autoFocus
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="networkSubnet" className="text-foreground">
                Subnet (CIDR)
              </Label>
              <Input
                id="networkSubnet"
                placeholder="10.0.0.0/24"
                value={formData.subnet}
                onChange={(e) =>
                  setFormData({ ...formData, subnet: e.target.value })
                }
                className="bg-background border-border text-foreground font-mono"
                disabled={isLoading}
              />
              <p className="text-xs text-muted-foreground">
                Prefix must be between /8 and /30.
              </p>
            </div>
            <div className="space-y-2">
              <Label htmlFor="networkGateway" className="text-foreground">
                Gateway (optional)
              </Label>
              <Input
                id="networkGateway"
                placeholder="10.0.0.1"
                value={formData.gateway}
                onChange={(e) =>
                  setFormData({ ...formData, gateway: e.target.value })
                }
                className="bg-background border-border text-foreground font-mono"
                disabled={isLoading}
              />
              <p className="text-xs text-muted-foreground">
                Defaults to the subnet&apos;s first host address. Changing it
                later only affects VMs created afterward.
              </p>
            </div>
            <DHCPFields value={dhcp} onChange={setDhcp} disabled={isLoading} />
          </div>
          <DialogFooter>
            <Button
              type="button"
              variant="outline"
              onClick={() => onOpenChange(false)}
              className="border-input text-foreground/80 hover:bg-accent"
              disabled={isLoading}
            >
              Cancel
            </Button>
            <Button
              type="submit"
              className="bg-primary hover:bg-primary/90"
              disabled={isLoading}
            >
              {isLoading ? (
                <>
                  <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                  Creating...
                </>
              ) : (
                "Create Network"
              )}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
