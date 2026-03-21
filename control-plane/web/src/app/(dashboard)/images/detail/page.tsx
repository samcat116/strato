"use client";

import { useSearchParams } from "next/navigation";
import Link from "next/link";
import {
  ArrowLeft,
  Cpu,
  HardDrive,
  MemoryStick,
  Clock,
  FileType,
  Hash,
  Settings,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { Badge } from "@/components/ui/badge";
import { useImage } from "@/lib/hooks/use-images";

function ImageStatusBadge({ status }: { status: string }) {
  const statusStyles: Record<string, string> = {
    ready: "bg-green-600",
    pending: "bg-yellow-600",
    uploading: "bg-blue-600",
    downloading: "bg-blue-600",
    validating: "bg-purple-600",
    error: "bg-red-600",
  };

  return (
    <Badge className={statusStyles[status] || "bg-gray-600"}>
      {status.charAt(0).toUpperCase() + status.slice(1)}
    </Badge>
  );
}

export default function ImageDetailPage() {
  const searchParams = useSearchParams();
  const id = searchParams.get("id") || "";
  const projectId = searchParams.get("projectId") || "";
  const { data: image, isLoading, error } = useImage(projectId, id);

  if (!id || !projectId) {
    return (
      <div className="max-w-4xl mx-auto">
        <div className="text-center py-12">
          <p className="text-gray-400 mb-4">
            {!id ? "No Image ID provided" : "No Project ID provided"}
          </p>
          <Link href="/images">
            <Button variant="outline" className="border-gray-600">
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
        <Skeleton className="h-8 w-48 bg-gray-700" />
        <Skeleton className="h-64 w-full bg-gray-700" />
      </div>
    );
  }

  if (error || !image) {
    return (
      <div className="max-w-4xl mx-auto">
        <div className="text-center py-12">
          <p className="text-gray-400 mb-4">Image not found or failed to load</p>
          <Link href="/images">
            <Button variant="outline" className="border-gray-600">
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
            className="text-sm text-gray-400 hover:text-gray-200 flex items-center mb-2"
          >
            <ArrowLeft className="h-4 w-4 mr-1" />
            Back to Images
          </Link>
          <div className="flex items-center gap-3">
            <h2 className="text-2xl font-semibold text-gray-100">{image.name}</h2>
            <ImageStatusBadge status={image.status} />
          </div>
          {image.description && (
            <p className="text-gray-400 mt-1">{image.description}</p>
          )}
        </div>
      </div>

      {/* Overview */}
      <div className="grid grid-cols-1 md:grid-cols-4 gap-4">
        <Card className="bg-gray-800 border-gray-700">
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium text-gray-400 flex items-center gap-2">
              <HardDrive className="h-4 w-4" />
              Size
            </CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-xl font-bold text-gray-100">
              {image.sizeFormatted}
            </div>
          </CardContent>
        </Card>
        <Card className="bg-gray-800 border-gray-700">
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium text-gray-400 flex items-center gap-2">
              <FileType className="h-4 w-4" />
              Format
            </CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-xl font-bold text-gray-100 uppercase">
              {image.format}
            </div>
          </CardContent>
        </Card>
        <Card className="bg-gray-800 border-gray-700">
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium text-gray-400 flex items-center gap-2">
              <Clock className="h-4 w-4" />
              Created
            </CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-sm font-medium text-gray-100">
              {image.createdAt
                ? new Date(image.createdAt).toLocaleDateString()
                : "-"}
            </div>
            <p className="text-sm text-gray-500">
              {image.createdAt
                ? new Date(image.createdAt).toLocaleTimeString()
                : ""}
            </p>
          </CardContent>
        </Card>
        <Card className="bg-gray-800 border-gray-700">
          <CardHeader className="pb-2">
            <CardTitle className="text-sm font-medium text-gray-400 flex items-center gap-2">
              <Hash className="h-4 w-4" />
              Checksum
            </CardTitle>
          </CardHeader>
          <CardContent>
            <div className="text-xs font-mono text-gray-100 truncate">
              {image.checksum || "Not available"}
            </div>
          </CardContent>
        </Card>
      </div>

      {/* Details */}
      <Card className="bg-gray-800 border-gray-700">
        <CardHeader>
          <CardTitle className="text-lg font-semibold text-gray-100">
            Details
          </CardTitle>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="grid grid-cols-2 gap-4 text-sm">
            <div>
              <p className="text-gray-400">ID</p>
              <p className="text-gray-100 font-mono">{image.id}</p>
            </div>
            <div>
              <p className="text-gray-400">Filename</p>
              <p className="text-gray-100">{image.filename}</p>
            </div>
            {image.sourceURL && (
              <div className="col-span-2">
                <p className="text-gray-400">Source URL</p>
                <p className="text-gray-100 break-all">{image.sourceURL}</p>
              </div>
            )}
            <div>
              <p className="text-gray-400">Last Updated</p>
              <p className="text-gray-100">
                {image.updatedAt
                  ? new Date(image.updatedAt).toLocaleString()
                  : "-"}
              </p>
            </div>
          </div>
        </CardContent>
      </Card>

      {/* Default VM Settings */}
      {(image.defaultCpu || image.defaultMemory || image.defaultDisk) && (
        <Card className="bg-gray-800 border-gray-700">
          <CardHeader>
            <CardTitle className="text-lg font-semibold text-gray-100 flex items-center gap-2">
              <Settings className="h-5 w-5" />
              Default VM Settings
            </CardTitle>
          </CardHeader>
          <CardContent>
            <div className="grid grid-cols-3 gap-4">
              <div className="flex items-center gap-2">
                <Cpu className="h-4 w-4 text-gray-400" />
                <div>
                  <p className="text-sm text-gray-400">CPU</p>
                  <p className="text-gray-100">
                    {image.defaultCpu ? `${image.defaultCpu} cores` : "Not set"}
                  </p>
                </div>
              </div>
              <div className="flex items-center gap-2">
                <MemoryStick className="h-4 w-4 text-gray-400" />
                <div>
                  <p className="text-sm text-gray-400">Memory</p>
                  <p className="text-gray-100">{formatMemory(image.defaultMemory)}</p>
                </div>
              </div>
              <div className="flex items-center gap-2">
                <HardDrive className="h-4 w-4 text-gray-400" />
                <div>
                  <p className="text-sm text-gray-400">Disk</p>
                  <p className="text-gray-100">{formatDisk(image.defaultDisk)}</p>
                </div>
              </div>
            </div>
          </CardContent>
        </Card>
      )}
    </div>
  );
}
