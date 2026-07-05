"use client";

import { useMemo, useState } from "react";
import Link from "next/link";
import { Loader2, Plus, Unlink } from "lucide-react";
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
import { VolumeStatusBadge } from "@/components/volumes";
import { volumesApi } from "@/lib/api/volumes";
import { useVolumes, useInvalidateVolumes } from "@/lib/hooks/use-volumes";
import { toast } from "sonner";
import type { VM } from "@/types/api";

const selectClassName =
  "w-full h-9 px-3 py-2 bg-gray-900 border border-gray-700 text-gray-100 rounded-md text-sm focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent disabled:opacity-50 disabled:cursor-not-allowed";

export function VMVolumesCard({ vm }: { vm: VM }) {
  const { data: volumes = [], isLoading } = useVolumes(vm.projectId);
  const invalidateVolumes = useInvalidateVolumes();

  const [attachOpen, setAttachOpen] = useState(false);
  const [attachVolumeId, setAttachVolumeId] = useState("");
  const [busyVolumeId, setBusyVolumeId] = useState<string | null>(null);
  const [isAttaching, setIsAttaching] = useState(false);

  const attachedVolumes = useMemo(
    () => volumes.filter((v) => v.vmId === vm.id),
    [volumes, vm.id]
  );
  const availableVolumes = useMemo(
    () => volumes.filter((v) => v.id && v.status === "available"),
    [volumes]
  );

  const handleAttach = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!attachVolumeId) {
      toast.error("Please select a volume");
      return;
    }
    setIsAttaching(true);
    try {
      await volumesApi.attach(attachVolumeId, { vmId: vm.id });
      toast.success("Volume attached");
      setAttachOpen(false);
      setAttachVolumeId("");
      invalidateVolumes();
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : "Failed to attach volume"
      );
    } finally {
      setIsAttaching(false);
    }
  };

  const handleDetach = async (volumeId: string, name: string) => {
    setBusyVolumeId(volumeId);
    try {
      await volumesApi.detach(volumeId);
      toast.success(`Detached ${name}`);
      invalidateVolumes();
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : "Failed to detach volume"
      );
    } finally {
      setBusyVolumeId(null);
    }
  };

  return (
    <Card className="bg-gray-800 border-gray-700">
      <CardHeader className="flex flex-row items-center justify-between space-y-0">
        <CardTitle className="text-lg font-semibold text-gray-100">
          Attached Volumes
        </CardTitle>
        <Button
          size="sm"
          variant="outline"
          className="border-gray-600 text-gray-300 hover:bg-gray-700"
          onClick={() => setAttachOpen(true)}
        >
          <Plus className="h-4 w-4 mr-2" />
          Attach Volume
        </Button>
      </CardHeader>
      <CardContent>
        {isLoading ? (
          <div className="space-y-2">
            {[...Array(2)].map((_, i) => (
              <Skeleton key={i} className="h-10 w-full bg-gray-700" />
            ))}
          </div>
        ) : attachedVolumes.length === 0 ? (
          <div className="text-center py-6 text-gray-400">
            No volumes attached to this VM.
          </div>
        ) : (
          <Table>
            <TableHeader className="bg-gray-900">
              <TableRow className="border-gray-700 hover:bg-gray-900">
                <TableHead className="text-gray-400 font-medium">
                  Device
                </TableHead>
                <TableHead className="text-gray-400 font-medium">
                  Name
                </TableHead>
                <TableHead className="text-gray-400 font-medium">
                  Size
                </TableHead>
                <TableHead className="text-gray-400 font-medium">
                  Status
                </TableHead>
                <TableHead className="text-gray-400 font-medium text-right">
                  Actions
                </TableHead>
              </TableRow>
            </TableHeader>
            <TableBody className="divide-y divide-gray-700">
              {attachedVolumes.map((volume) => (
                <TableRow
                  key={volume.id}
                  className="border-gray-700 hover:bg-gray-800/50"
                >
                  <TableCell className="text-gray-300 font-mono text-sm">
                    {volume.deviceName ?? "—"}
                  </TableCell>
                  <TableCell>
                    <Link
                      href="/storage/volumes"
                      className="font-medium text-gray-100 hover:text-blue-400"
                    >
                      {volume.name}
                    </Link>
                  </TableCell>
                  <TableCell className="text-gray-300">
                    {volume.sizeFormatted}
                  </TableCell>
                  <TableCell>
                    <VolumeStatusBadge status={volume.status} />
                  </TableCell>
                  <TableCell className="text-right">
                    <Button
                      size="sm"
                      variant="ghost"
                      className="text-yellow-400 hover:text-yellow-300 hover:bg-yellow-500/10"
                      onClick={() => handleDetach(volume.id!, volume.name)}
                      disabled={
                        volume.status !== "attached" ||
                        busyVolumeId === volume.id
                      }
                    >
                      {busyVolumeId === volume.id ? (
                        <Loader2 className="h-4 w-4 animate-spin" />
                      ) : (
                        <Unlink className="h-4 w-4" />
                      )}
                    </Button>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
      </CardContent>

      {/* Attach dialog */}
      <Dialog open={attachOpen} onOpenChange={setAttachOpen}>
        <DialogContent className="bg-gray-800 border-gray-700 text-gray-100">
          <DialogHeader>
            <DialogTitle>Attach Volume to {vm.name}</DialogTitle>
            <DialogDescription className="text-gray-400">
              Select an available volume from this VM&apos;s project.
            </DialogDescription>
          </DialogHeader>
          <form onSubmit={handleAttach}>
            <div className="space-y-4 py-4">
              <div className="space-y-2">
                <Label htmlFor="vmAttachVolume" className="text-gray-200">
                  Volume
                </Label>
                {availableVolumes.length === 0 ? (
                  <div className="text-sm text-gray-400 py-2">
                    No available volumes.{" "}
                    <Link
                      href="/storage/volumes"
                      className="text-blue-400 hover:underline"
                    >
                      Create a volume
                    </Link>{" "}
                    first.
                  </div>
                ) : (
                  <select
                    id="vmAttachVolume"
                    value={attachVolumeId}
                    onChange={(e) => setAttachVolumeId(e.target.value)}
                    disabled={isAttaching}
                    className={selectClassName}
                  >
                    <option value="" disabled>
                      Select a volume
                    </option>
                    {availableVolumes.map((volume) => (
                      <option key={volume.id} value={volume.id!}>
                        {volume.name} ({volume.sizeFormatted})
                      </option>
                    ))}
                  </select>
                )}
              </div>
            </div>
            <DialogFooter>
              <Button
                type="button"
                variant="outline"
                onClick={() => setAttachOpen(false)}
                className="border-gray-600 text-gray-300 hover:bg-gray-700"
                disabled={isAttaching}
              >
                Cancel
              </Button>
              <Button
                type="submit"
                className="bg-blue-600 hover:bg-blue-700"
                disabled={isAttaching || availableVolumes.length === 0}
              >
                {isAttaching ? (
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
    </Card>
  );
}
