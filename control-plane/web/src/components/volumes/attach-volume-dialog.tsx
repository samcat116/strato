"use client";

import { useMemo, useState } from "react";
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
import { volumesApi } from "@/lib/api/volumes";
import { useVMs } from "@/lib/hooks/use-vms";
import { toast } from "sonner";
import type { Volume } from "@/types/api";

interface AttachVolumeDialogProps {
  volume: Volume;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onSuccess?: () => void;
}

const selectClassName =
  "w-full h-9 px-3 py-2 bg-gray-900 border border-gray-700 text-gray-100 rounded-md text-sm focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent disabled:opacity-50 disabled:cursor-not-allowed";

export function AttachVolumeDialog({
  volume,
  open,
  onOpenChange,
  onSuccess,
}: AttachVolumeDialogProps) {
  const [isLoading, setIsLoading] = useState(false);
  const [vmId, setVmId] = useState("");
  const [deviceName, setDeviceName] = useState("");
  const { data: vms, isLoading: vmsLoading } = useVMs();

  // Volumes can only attach to VMs in the same project
  const candidateVMs = useMemo(
    () =>
      (vms ?? []).filter(
        (vm) => !volume.projectId || vm.projectId === volume.projectId
      ),
    [vms, volume.projectId]
  );

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!vmId) {
      toast.error("Please select a VM");
      return;
    }

    setIsLoading(true);
    try {
      await volumesApi.attach(volume.id!, {
        vmId,
        deviceName: deviceName.trim() || undefined,
      });
      toast.success(`Attached ${volume.name}`);
      onOpenChange(false);
      onSuccess?.();
      setVmId("");
      setDeviceName("");
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : "Failed to attach volume"
      );
    } finally {
      setIsLoading(false);
    }
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="bg-gray-800 border-gray-700 text-gray-100">
        <DialogHeader>
          <DialogTitle>Attach {volume.name}</DialogTitle>
          <DialogDescription className="text-gray-400">
            Attach this volume to a virtual machine as an additional disk.
          </DialogDescription>
        </DialogHeader>
        <form onSubmit={handleSubmit}>
          <div className="space-y-4 py-4">
            <div className="space-y-2">
              <Label htmlFor="attachVm" className="text-gray-200">
                Virtual Machine
              </Label>
              {vmsLoading ? (
                <div className="flex items-center gap-2 text-gray-400 text-sm">
                  <Loader2 className="h-4 w-4 animate-spin" />
                  Loading VMs...
                </div>
              ) : candidateVMs.length === 0 ? (
                <div className="text-sm text-gray-400 py-2">
                  No VMs available in this volume&apos;s project.
                </div>
              ) : (
                <select
                  id="attachVm"
                  value={vmId}
                  onChange={(e) => setVmId(e.target.value)}
                  disabled={isLoading}
                  className={selectClassName}
                >
                  <option value="" disabled>
                    Select a VM
                  </option>
                  {candidateVMs.map((vm) => (
                    <option key={vm.id} value={vm.id}>
                      {vm.name} ({vm.status})
                    </option>
                  ))}
                </select>
              )}
            </div>
            <div className="space-y-2">
              <Label htmlFor="attachDeviceName" className="text-gray-200">
                Device Name (optional)
              </Label>
              <Input
                id="attachDeviceName"
                placeholder="Auto-assigned (disk0, disk1, ...)"
                value={deviceName}
                onChange={(e) => setDeviceName(e.target.value)}
                className="bg-gray-900 border-gray-700 text-gray-100"
                disabled={isLoading}
              />
            </div>
          </div>
          <DialogFooter>
            <Button
              type="button"
              variant="outline"
              onClick={() => onOpenChange(false)}
              className="border-gray-600 text-gray-300 hover:bg-gray-700"
              disabled={isLoading}
            >
              Cancel
            </Button>
            <Button
              type="submit"
              className="bg-blue-600 hover:bg-blue-700"
              disabled={isLoading || candidateVMs.length === 0}
            >
              {isLoading ? (
                <>
                  <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                  Attaching...
                </>
              ) : (
                "Attach"
              )}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
