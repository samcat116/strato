"use client";

import { useState } from "react";
import { useSearchParams } from "next/navigation";
import Link from "next/link";
import {
  ArrowLeft,
  Cpu,
  Download,
  HardDrive,
  MemoryStick,
  Clock,
  FileType,
  Hash,
  Pencil,
  Settings,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { Badge } from "@/components/ui/badge";
import { EditImageDialog } from "@/components/images/edit-image-dialog";
import { useImage, useDeleteArtifact } from "@/lib/hooks/use-images";
import { imagesApi } from "@/lib/api/images";
import type { ArtifactKind } from "@/types/api";

function formatBytes(bytes: number): string {
  const gb = bytes / 1024 / 1024 / 1024;
  if (gb >= 1) return `${gb.toFixed(2)} GB`;
  const mb = bytes / 1024 / 1024;
  if (mb >= 1) return `${mb.toFixed(2)} MB`;
  return `${(bytes / 1024).toFixed(2)} KB`;
}

function ImageStatusBadge({ status }: { status: string }) {
  const statusStyles: Record<string, string> = {
    ready: "bg-green-600",
    pending: "bg-yellow-600",
    uploading: "bg-primary",
    downloading: "bg-primary",
    validating: "bg-purple-600",
    error: "bg-red-600",
  };

  return (
    <Badge className={statusStyles[status] || "bg-muted"}>
      {status.charAt(0).toUpperCase() + status.slice(1)}
    </Badge>
  );
}

export default function ImageDetailPage() {
  const searchParams = useSearchParams();
  const id = searchParams.get("id") || "";
  const projectId = searchParams.get("projectId") || "";
  const { data: image, isLoading, error } = useImage(projectId, id);
  const [editOpen, setEditOpen] = useState(false);
  const deleteArtifact = useDeleteArtifact(projectId);

  if (!id || !projectId) {
    return (
      <div className="max-w-4xl mx-auto">
        <div className="text-center py-12">
          <p className="text-muted-foreground mb-4">
            {!id ? "No Image ID provided" : "No Project ID provided"}
          </p>
          <Link href="/images">
            <Button variant="outline" className="border-input">
              <ArrowLeft className="h-4 w-4 mr-2" />
              Back to Images
            </Button>
          </Link>
        </div>
      </div>
    );
  }

  if (isLoading) {
    return (
      <div className="max-w-4xl mx-auto space-y-6">
        <Skeleton className="h-8 w-48 bg-muted" />
        <Skeleton className="h-64 w-full bg-muted" />
      </div>
    );
  }

  if (error || !image) {
    return (
      <div className="max-w-4xl mx-auto">
        <div className="text-center py-12">
          <p className="text-muted-foreground mb-4">Image not found or failed to load</p>
          <Link href="/images">
            <Button variant="outline" className="border-input">
              <ArrowLeft className="h-4 w-4 mr-2" />
              Back to Images
            </Button>
          </Link>
        </div>
      </div>
    );
  }

  const formatMemory = (bytes: number | undefined) => {
    if (!bytes) return "Not set";
    const gb = bytes / 1024 / 1024 / 1024;
    if (gb >= 1) {
      return `${gb.toFixed(1)} GB`;
    }
    const mb = bytes / 1024 / 1024;
    return `${mb.toFixed(0)} MB`;
  };

  const formatDisk = (bytes: number | undefined) => {
    if (!bytes) return "Not set";
    const gb = bytes / 1024 / 1024 / 1024;
    return `${gb.toFixed(0)} GB`;
  };

  return (
    <div className="max-w-4xl mx-auto space-y-6">
      {/* Header */}
      <div className="flex items-start justify-between">
        <div>
          <Link
            href="/images"
            className="text-sm text-muted-foreground hover:text-foreground flex items-center mb-2"
          >
            <ArrowLeft className="h-4 w-4 mr-1" />
            Back to Images
          </Link>
          <div className="flex items-center gap-3">
            <h2 className="text-2xl font-semibold text-foreground">{image.name}</h2>
            <ImageStatusBadge status={image.status} />
          </div>
          {image.description && (
            <p className="text-muted-foreground mt-1">{image.description}</p>
          )}
        </div>
        <div className="flex items-center gap-2">
          <Button
            variant="outline"
            className="border-input"
            disabled={image.status !== "ready"}
            onClick={() =>
              window.open(imagesApi.getDownloadURL(projectId, id), "_blank")
            }
          >
            <Download className="h-4 w-4 mr-2" />
            Download
          </Button>
          <Button
            variant="outline"
            className="border-input"
            onClick={() => setEditOpen(true)}
          >
            <Pencil className="h-4 w-4 mr-2" />
            Edit
          </Button>
        </div>
      </div>

      {editOpen && (
        <EditImageDialog
          image={image}
          projectId={projectId}
          open={editOpen}
          onOpenChange={setEditOpen}
        />
      )}

      {/* Overview */}
      <div className="grid grid-cols-1 md:grid-cols-4 gap-4">
        <Card className="bg-card border-border">
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium text-muted-foreground flex items-center gap-2">
              <HardDrive className="h-4 w-4" />
              Size
            </CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-xl font-bold text-foreground">
              {image.sizeFormatted}
            </div>
          </CardContent>
        </Card>
        <Card className="bg-card border-border">
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium text-muted-foreground flex items-center gap-2">
              <FileType className="h-4 w-4" />
              Format
            </CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-xl font-bold text-foreground uppercase">
              {image.format}
            </div>
          </CardContent>
        </Card>
        <Card className="bg-card border-border">
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium text-muted-foreground flex items-center gap-2">
              <Clock className="h-4 w-4" />
              Created
            </CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-sm font-medium text-foreground">
              {image.createdAt
                ? new Date(image.createdAt).toLocaleDateString()
                : "-"}
            </div>
            <p className="text-sm text-muted-foreground">
              {image.createdAt
                ? new Date(image.createdAt).toLocaleTimeString()
                : ""}
            </p>
          </CardContent>
        </Card>
        <Card className="bg-card border-border">
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium text-muted-foreground flex items-center gap-2">
              <Hash className="h-4 w-4" />
              Checksum
            </CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-xs font-mono text-foreground truncate">
              {image.checksum || "Not available"}
            </div>
          </CardContent>
        </Card>
      </div>

      {/* Details */}
      <Card className="bg-card border-border">
        <CardHeader>
          <CardTitle className="text-lg font-semibold text-foreground">
            Details
          </CardTitle>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="grid grid-cols-2 gap-4 text-sm">
            <div>
              <p className="text-muted-foreground">ID</p>
              <p className="text-foreground font-mono">{image.id}</p>
            </div>
            <div>
              <p className="text-muted-foreground">Filename</p>
              <p className="text-foreground">{image.filename}</p>
            </div>
            {image.sourceURL && (
              <div className="col-span-2">
                <p className="text-muted-foreground">Source URL</p>
                <p className="text-foreground break-all">{image.sourceURL}</p>
              </div>
            )}
            <div>
              <p className="text-muted-foreground">Last Updated</p>
              <p className="text-foreground">
                {image.updatedAt
                  ? new Date(image.updatedAt).toLocaleString()
                  : "-"}
              </p>
            </div>
          </div>
        </CardContent>
      </Card>

      {/* Artifacts */}
      <Card className="bg-card border-border">
        <CardHeader>
          <CardTitle className="text-lg font-semibold text-foreground flex items-center justify-between">
            <span>Artifacts</span>
            {image.compatibleHypervisors &&
              image.compatibleHypervisors.length > 0 && (
                <span className="flex items-center gap-1">
                  {image.compatibleHypervisors.map((h) => (
                    <Badge
                      key={h}
                      variant="outline"
                      className="border-input text-foreground/80 capitalize"
                    >
                      {h}
                    </Badge>
                  ))}
                </span>
              )}
          </CardTitle>
        </CardHeader>
        <CardContent>
          {image.artifacts && image.artifacts.length > 0 ? (
            <div className="space-y-2">
              {image.artifacts.map((artifact) => (
                <div
                  key={artifact.kind}
                  className="flex items-center justify-between rounded-md bg-muted/50 px-3 py-2"
                >
                  <div className="flex items-center gap-3 min-w-0">
                    <Badge className="bg-muted text-foreground">
                      {artifact.kind}
                    </Badge>
                    <span className="text-sm text-foreground truncate">
                      {artifact.filename}
                    </span>
                    {artifact.status === "ready" ? (
                      <span className="text-xs text-muted-foreground">
                        {formatBytes(artifact.size)}
                        {artifact.format ? ` · ${artifact.format}` : ""}
                      </span>
                    ) : artifact.status === "error" ? (
                      <span className="text-xs text-red-600 truncate">
                        {artifact.errorMessage || "Fetch failed"}
                      </span>
                    ) : (
                      <span className="text-xs text-blue-600">
                        {artifact.status === "downloading"
                          ? `Downloading${
                              artifact.downloadProgress != null
                                ? ` ${artifact.downloadProgress}%`
                                : "..."
                            }`
                          : "Pending..."}
                      </span>
                    )}
                  </div>
                  <Button
                    variant="ghost"
                    size="sm"
                    className="text-red-600 hover:text-red-700 hover:bg-accent"
                    disabled={deleteArtifact.isPending}
                    onClick={() =>
                      deleteArtifact.mutate({
                        imageId: id,
                        kind: artifact.kind as ArtifactKind,
                      })
                    }
                  >
                    Remove
                  </Button>
                </div>
              ))}
            </div>
          ) : (
            <p className="text-sm text-muted-foreground">
              No artifacts registered yet. Firecracker images need a kernel and
              a rootfs; QEMU images need a disk image.
            </p>
          )}
        </CardContent>
      </Card>

      {/* Default VM Settings */}
      {(image.defaultCpu || image.defaultMemory || image.defaultDisk) && (
        <Card className="bg-card border-border">
          <CardHeader>
            <CardTitle className="text-lg font-semibold text-foreground flex items-center gap-2">
              <Settings className="h-5 w-5" />
              Default VM Settings
            </CardTitle>
          </CardHeader>
          <CardContent>
            <div className="grid grid-cols-3 gap-4">
              <div className="flex items-center gap-2">
                <Cpu className="h-4 w-4 text-muted-foreground" />
                <div>
                  <p className="text-sm text-muted-foreground">CPU</p>
                  <p className="text-foreground">
                    {image.defaultCpu ? `${image.defaultCpu} cores` : "Not set"}
                  </p>
                </div>
              </div>
              <div className="flex items-center gap-2">
                <MemoryStick className="h-4 w-4 text-muted-foreground" />
                <div>
                  <p className="text-sm text-muted-foreground">Memory</p>
                  <p className="text-foreground">{formatMemory(image.defaultMemory)}</p>
                </div>
              </div>
              <div className="flex items-center gap-2">
                <HardDrive className="h-4 w-4 text-muted-foreground" />
                <div>
                  <p className="text-sm text-muted-foreground">Disk</p>
                  <p className="text-foreground">{formatDisk(image.defaultDisk)}</p>
                </div>
              </div>
            </div>
          </CardContent>
        </Card>
      )}
    </div>
  );
}
