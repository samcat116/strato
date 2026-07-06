"use client";

import { useState, useRef } from "react";
import { Upload, Link as LinkIcon, X, Cpu } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import {
  useCreateImageFromURL,
  useUploadImage,
  useCreateEmptyImage,
  useUploadArtifact,
  useFetchArtifact,
} from "@/lib/hooks/use-images";
import type { CPUArchitecture } from "@/types/api";

const ARCHITECTURES: CPUArchitecture[] = ["x86_64", "arm64"];

interface UploadImageDialogProps {
  projectId: string;
  onSuccess?: () => void;
}

export function UploadImageDialog({
  projectId,
  onSuccess,
}: UploadImageDialogProps) {
  const [open, setOpen] = useState(false);
  const [name, setName] = useState("");
  const [description, setDescription] = useState("");
  const [architecture, setArchitecture] = useState<CPUArchitecture>("x86_64");
  const [sourceURL, setSourceURL] = useState("");
  const [selectedFile, setSelectedFile] = useState<File | null>(null);
  const [uploadProgress, setUploadProgress] = useState(0);
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Firecracker (kernel + rootfs) tab state.
  const [fcMode, setFcMode] = useState<"upload" | "url">("upload");
  const [kernelFile, setKernelFile] = useState<File | null>(null);
  const [rootfsFile, setRootfsFile] = useState<File | null>(null);
  const [initramfsFile, setInitramfsFile] = useState<File | null>(null);
  const [kernelURL, setKernelURL] = useState("");
  const [rootfsURL, setRootfsURL] = useState("");
  const [initramfsURL, setInitramfsURL] = useState("");
  const [uploadPhase, setUploadPhase] = useState<string | null>(null);

  const fileInputRef = useRef<HTMLInputElement>(null);

  const createFromURL = useCreateImageFromURL(projectId);
  const uploadImage = useUploadImage(projectId);
  const createEmptyImage = useCreateEmptyImage(projectId);
  const uploadArtifact = useUploadArtifact(projectId);
  const fetchArtifact = useFetchArtifact(projectId);

  const resetForm = () => {
    setName("");
    setDescription("");
    setArchitecture("x86_64");
    setSourceURL("");
    setSelectedFile(null);
    setFcMode("upload");
    setKernelFile(null);
    setRootfsFile(null);
    setInitramfsFile(null);
    setKernelURL("");
    setRootfsURL("");
    setInitramfsURL("");
    setUploadPhase(null);
    setUploadProgress(0);
    setError(null);
  };

  const handleClose = () => {
    if (!isSubmitting) {
      resetForm();
      setOpen(false);
    }
  };

  const handleFileSelect = (event: React.ChangeEvent<HTMLInputElement>) => {
    const file = event.target.files?.[0];
    if (file) {
      setSelectedFile(file);
      // Auto-fill name from filename if empty
      if (!name) {
        const fileName = file.name.replace(/\.(qcow2|img|raw|iso)$/i, "");
        setName(fileName);
      }
    }
  };

  const handleDrop = (event: React.DragEvent) => {
    event.preventDefault();
    const file = event.dataTransfer.files?.[0];
    if (file) {
      setSelectedFile(file);
      if (!name) {
        const fileName = file.name.replace(/\.(qcow2|img|raw|iso)$/i, "");
        setName(fileName);
      }
    }
  };

  const handleDragOver = (event: React.DragEvent) => {
    event.preventDefault();
  };

  const handleSubmitURL = async () => {
    if (!name || !sourceURL) {
      setError("Name and URL are required");
      return;
    }

    setIsSubmitting(true);
    setError(null);

    try {
      await createFromURL.mutateAsync({
        name,
        description: description || undefined,
        architecture,
        sourceURL,
      });
      handleClose();
      onSuccess?.();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to create image");
    } finally {
      setIsSubmitting(false);
    }
  };

  const handleSubmitUpload = async () => {
    if (!name || !selectedFile) {
      setError("Name and file are required");
      return;
    }

    setIsSubmitting(true);
    setError(null);
    setUploadProgress(0);

    try {
      await uploadImage.mutateAsync({
        file: selectedFile,
        metadata: {
          name,
          description: description || undefined,
          architecture,
        },
        onProgress: setUploadProgress,
      });
      handleClose();
      onSuccess?.();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to upload image");
    } finally {
      setIsSubmitting(false);
    }
  };

  const handleSubmitFirecracker = async () => {
    const uploadValid = kernelFile && rootfsFile;
    const urlValid = kernelURL && rootfsURL;
    if (!name || (fcMode === "upload" ? !uploadValid : !urlValid)) {
      setError("Name, kernel, and rootfs are required");
      return;
    }

    setIsSubmitting(true);
    setError(null);
    setUploadProgress(0);

    try {
      // 1. Create the image shell, then 2. attach each artifact. The image
      // becomes usable once kernel + rootfs are both registered.
      setUploadPhase("Creating image");
      const image = await createEmptyImage.mutateAsync({
        name,
        description: description || undefined,
        architecture,
      });
      if (!image.id) {
        throw new Error("Image was created without an ID");
      }

      const kinds: ("kernel" | "rootfs" | "initramfs")[] = ["kernel", "rootfs"];

      if (fcMode === "upload") {
        const files: Record<string, File | null> = {
          kernel: kernelFile,
          rootfs: rootfsFile,
          initramfs: initramfsFile,
        };
        if (initramfsFile) kinds.push("initramfs");
        for (const kind of kinds) {
          const file = files[kind];
          if (!file) continue;
          setUploadPhase(`Uploading ${kind}`);
          setUploadProgress(0);
          await uploadArtifact.mutateAsync({
            imageId: image.id,
            kind,
            file,
            onProgress: setUploadProgress,
          });
        }
      } else {
        const urls: Record<string, string> = {
          kernel: kernelURL,
          rootfs: rootfsURL,
          initramfs: initramfsURL,
        };
        if (initramfsURL) kinds.push("initramfs");
        for (const kind of kinds) {
          const sourceURL = urls[kind];
          if (!sourceURL) continue;
          setUploadPhase(`Queueing ${kind}`);
          await fetchArtifact.mutateAsync({
            imageId: image.id,
            kind,
            sourceURL,
          });
        }
      }

      handleClose();
      onSuccess?.();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to create image");
    } finally {
      setIsSubmitting(false);
      setUploadPhase(null);
    }
  };

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button className="bg-blue-600 hover:bg-blue-700">
          <Upload className="mr-2 h-4 w-4" />
          Add Image
        </Button>
      </DialogTrigger>
      <DialogContent className="bg-gray-800 border-gray-700 text-gray-100 sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>Add Image</DialogTitle>
          <DialogDescription className="text-gray-400">
            Upload a disk image, register Firecracker kernel + rootfs, or fetch
            from a URL.
          </DialogDescription>
        </DialogHeader>

        <Tabs defaultValue="upload" className="w-full">
          <TabsList className="grid w-full grid-cols-3 bg-gray-900">
            <TabsTrigger
              value="upload"
              className="data-[state=active]:bg-gray-700"
            >
              <Upload className="mr-2 h-4 w-4" />
              Disk
            </TabsTrigger>
            <TabsTrigger
              value="firecracker"
              className="data-[state=active]:bg-gray-700"
            >
              <Cpu className="mr-2 h-4 w-4" />
              Firecracker
            </TabsTrigger>
            <TabsTrigger
              value="url"
              className="data-[state=active]:bg-gray-700"
            >
              <LinkIcon className="mr-2 h-4 w-4" />
              From URL
            </TabsTrigger>
          </TabsList>

          <TabsContent value="upload" className="space-y-4 mt-4">
            <div className="space-y-2">
              <Label htmlFor="name">Name</Label>
              <Input
                id="name"
                value={name}
                onChange={(e) => setName(e.target.value)}
                placeholder="Ubuntu 22.04 Server"
                className="bg-gray-700 border-gray-600"
              />
            </div>

            <div className="space-y-2">
              <Label htmlFor="description">Description (optional)</Label>
              <Input
                id="description"
                value={description}
                onChange={(e) => setDescription(e.target.value)}
                placeholder="Ubuntu 22.04 LTS server image"
                className="bg-gray-700 border-gray-600"
              />
            </div>

            <div className="space-y-2">
              <Label htmlFor="upload-arch">Architecture</Label>
              <select
                id="upload-arch"
                value={architecture}
                onChange={(e) =>
                  setArchitecture(e.target.value as CPUArchitecture)
                }
                className="w-full rounded-md bg-gray-700 border border-gray-600 px-3 py-2 text-sm text-gray-100"
              >
                {ARCHITECTURES.map((arch) => (
                  <option key={arch} value={arch}>
                    {arch}
                  </option>
                ))}
              </select>
            </div>

            <div className="space-y-2">
              <Label>Image File</Label>
              <div
                className="border-2 border-dashed border-gray-600 rounded-lg p-6 text-center cursor-pointer hover:border-gray-500 transition-colors"
                onClick={() => fileInputRef.current?.click()}
                onDrop={handleDrop}
                onDragOver={handleDragOver}
              >
                {selectedFile ? (
                  <div className="flex items-center justify-center gap-2">
                    <span className="text-gray-300">{selectedFile.name}</span>
                    <Button
                      variant="ghost"
                      size="sm"
                      className="h-6 w-6 p-0"
                      onClick={(e) => {
                        e.stopPropagation();
                        setSelectedFile(null);
                      }}
                    >
                      <X className="h-4 w-4" />
                    </Button>
                  </div>
                ) : (
                  <div className="text-gray-400">
                    <Upload className="h-8 w-8 mx-auto mb-2" />
                    <p>Click to select or drag and drop</p>
                    <p className="text-sm text-gray-500">
                      QCOW2, RAW, IMG, or ISO files
                    </p>
                  </div>
                )}
              </div>
              <input
                ref={fileInputRef}
                type="file"
                accept=".qcow2,.img,.raw,.iso"
                onChange={handleFileSelect}
                className="hidden"
              />
            </div>

            {uploadProgress > 0 && uploadProgress < 100 && (
              <div className="space-y-1">
                <div className="flex justify-between text-sm text-gray-400">
                  <span>Uploading...</span>
                  <span>{uploadProgress}%</span>
                </div>
                <div className="h-2 bg-gray-700 rounded-full overflow-hidden">
                  <div
                    className="h-full bg-blue-500 transition-all duration-300"
                    style={{ width: `${uploadProgress}%` }}
                  />
                </div>
              </div>
            )}

            {error && (
              <p className="text-sm text-red-400">{error}</p>
            )}

            <DialogFooter>
              <Button
                variant="outline"
                onClick={handleClose}
                disabled={isSubmitting}
                className="border-gray-600"
              >
                Cancel
              </Button>
              <Button
                onClick={handleSubmitUpload}
                disabled={!name || !selectedFile || isSubmitting}
                className="bg-blue-600 hover:bg-blue-700"
              >
                {isSubmitting ? "Uploading..." : "Upload"}
              </Button>
            </DialogFooter>
          </TabsContent>

          <TabsContent value="firecracker" className="space-y-4 mt-4">
            <p className="text-xs text-gray-400">
              Register a kernel + root filesystem (and optional initramfs) so the
              image can boot on Firecracker hypervisors.
            </p>

            <div className="space-y-2">
              <Label htmlFor="fc-name">Name</Label>
              <Input
                id="fc-name"
                value={name}
                onChange={(e) => setName(e.target.value)}
                placeholder="Alpine 3.20 (microVM)"
                className="bg-gray-700 border-gray-600"
              />
            </div>

            <div className="space-y-2">
              <Label htmlFor="fc-description">Description (optional)</Label>
              <Input
                id="fc-description"
                value={description}
                onChange={(e) => setDescription(e.target.value)}
                placeholder="Minimal microVM image"
                className="bg-gray-700 border-gray-600"
              />
            </div>

            <div className="space-y-2">
              <Label htmlFor="fc-arch">Architecture</Label>
              <select
                id="fc-arch"
                value={architecture}
                onChange={(e) =>
                  setArchitecture(e.target.value as CPUArchitecture)
                }
                className="w-full rounded-md bg-gray-700 border border-gray-600 px-3 py-2 text-sm text-gray-100"
              >
                {ARCHITECTURES.map((arch) => (
                  <option key={arch} value={arch}>
                    {arch}
                  </option>
                ))}
              </select>
            </div>

            <div className="flex rounded-md bg-gray-900 p-1 text-sm">
              <button
                type="button"
                onClick={() => setFcMode("upload")}
                className={`flex-1 rounded px-3 py-1.5 ${
                  fcMode === "upload"
                    ? "bg-gray-700 text-gray-100"
                    : "text-gray-400 hover:text-gray-200"
                }`}
              >
                Upload files
              </button>
              <button
                type="button"
                onClick={() => setFcMode("url")}
                className={`flex-1 rounded px-3 py-1.5 ${
                  fcMode === "url"
                    ? "bg-gray-700 text-gray-100"
                    : "text-gray-400 hover:text-gray-200"
                }`}
              >
                From URLs
              </button>
            </div>

            {fcMode === "upload" ? (
              <>
                <div className="space-y-2">
                  <Label htmlFor="fc-kernel">Kernel</Label>
                  <input
                    id="fc-kernel"
                    type="file"
                    onChange={(e) => setKernelFile(e.target.files?.[0] ?? null)}
                    className="block w-full text-sm text-gray-300 file:mr-3 file:rounded-md file:border-0 file:bg-gray-700 file:px-3 file:py-1.5 file:text-gray-100 hover:file:bg-gray-600"
                  />
                  <p className="text-xs text-gray-500">
                    Uncompressed kernel image (e.g. vmlinux).
                  </p>
                </div>

                <div className="space-y-2">
                  <Label htmlFor="fc-rootfs">Root filesystem</Label>
                  <input
                    id="fc-rootfs"
                    type="file"
                    onChange={(e) => setRootfsFile(e.target.files?.[0] ?? null)}
                    className="block w-full text-sm text-gray-300 file:mr-3 file:rounded-md file:border-0 file:bg-gray-700 file:px-3 file:py-1.5 file:text-gray-100 hover:file:bg-gray-600"
                  />
                  <p className="text-xs text-gray-500">
                    Root filesystem image (raw/ext4/squashfs or qcow2).
                  </p>
                </div>

                <div className="space-y-2">
                  <Label htmlFor="fc-initramfs">Initramfs (optional)</Label>
                  <input
                    id="fc-initramfs"
                    type="file"
                    onChange={(e) =>
                      setInitramfsFile(e.target.files?.[0] ?? null)
                    }
                    className="block w-full text-sm text-gray-300 file:mr-3 file:rounded-md file:border-0 file:bg-gray-700 file:px-3 file:py-1.5 file:text-gray-100 hover:file:bg-gray-600"
                  />
                </div>
              </>
            ) : (
              <>
                <div className="space-y-2">
                  <Label htmlFor="fc-kernel-url">Kernel URL</Label>
                  <Input
                    id="fc-kernel-url"
                    type="url"
                    value={kernelURL}
                    onChange={(e) => setKernelURL(e.target.value)}
                    placeholder="https://.../vmlinux"
                    className="bg-gray-700 border-gray-600"
                  />
                </div>

                <div className="space-y-2">
                  <Label htmlFor="fc-rootfs-url">Root filesystem URL</Label>
                  <Input
                    id="fc-rootfs-url"
                    type="url"
                    value={rootfsURL}
                    onChange={(e) => setRootfsURL(e.target.value)}
                    placeholder="https://.../rootfs.ext4"
                    className="bg-gray-700 border-gray-600"
                  />
                </div>

                <div className="space-y-2">
                  <Label htmlFor="fc-initramfs-url">
                    Initramfs URL (optional)
                  </Label>
                  <Input
                    id="fc-initramfs-url"
                    type="url"
                    value={initramfsURL}
                    onChange={(e) => setInitramfsURL(e.target.value)}
                    placeholder="https://.../initramfs.cpio.gz"
                    className="bg-gray-700 border-gray-600"
                  />
                </div>

                <p className="text-xs text-gray-500">
                  Artifacts download in the background; the image becomes ready
                  once the kernel and rootfs finish.
                </p>
              </>
            )}

            {isSubmitting && uploadPhase && (
              <div className="space-y-1">
                <div className="flex justify-between text-sm text-gray-400">
                  <span>{uploadPhase}...</span>
                  {uploadProgress > 0 && <span>{uploadProgress}%</span>}
                </div>
                <div className="h-2 bg-gray-700 rounded-full overflow-hidden">
                  <div
                    className="h-full bg-blue-500 transition-all duration-300"
                    style={{ width: `${uploadProgress}%` }}
                  />
                </div>
              </div>
            )}

            {error && <p className="text-sm text-red-400">{error}</p>}

            <DialogFooter>
              <Button
                variant="outline"
                onClick={handleClose}
                disabled={isSubmitting}
                className="border-gray-600"
              >
                Cancel
              </Button>
              <Button
                onClick={handleSubmitFirecracker}
                disabled={
                  !name ||
                  isSubmitting ||
                  (fcMode === "upload"
                    ? !kernelFile || !rootfsFile
                    : !kernelURL || !rootfsURL)
                }
                className="bg-blue-600 hover:bg-blue-700"
              >
                {isSubmitting ? "Registering..." : "Register Image"}
              </Button>
            </DialogFooter>
          </TabsContent>

          <TabsContent value="url" className="space-y-4 mt-4">
            <div className="space-y-2">
              <Label htmlFor="url-name">Name</Label>
              <Input
                id="url-name"
                value={name}
                onChange={(e) => setName(e.target.value)}
                placeholder="Ubuntu 22.04 Server"
                className="bg-gray-700 border-gray-600"
              />
            </div>

            <div className="space-y-2">
              <Label htmlFor="url-description">Description (optional)</Label>
              <Input
                id="url-description"
                value={description}
                onChange={(e) => setDescription(e.target.value)}
                placeholder="Ubuntu 22.04 LTS server image"
                className="bg-gray-700 border-gray-600"
              />
            </div>

            <div className="space-y-2">
              <Label htmlFor="url-arch">Architecture</Label>
              <select
                id="url-arch"
                value={architecture}
                onChange={(e) =>
                  setArchitecture(e.target.value as CPUArchitecture)
                }
                className="w-full rounded-md bg-gray-700 border border-gray-600 px-3 py-2 text-sm text-gray-100"
              >
                {ARCHITECTURES.map((arch) => (
                  <option key={arch} value={arch}>
                    {arch}
                  </option>
                ))}
              </select>
            </div>

            <div className="space-y-2">
              <Label htmlFor="source-url">Source URL</Label>
              <Input
                id="source-url"
                type="url"
                value={sourceURL}
                onChange={(e) => setSourceURL(e.target.value)}
                placeholder="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
                className="bg-gray-700 border-gray-600"
              />
              <p className="text-xs text-gray-500">
                The image will be downloaded in the background.
              </p>
            </div>

            {error && (
              <p className="text-sm text-red-400">{error}</p>
            )}

            <DialogFooter>
              <Button
                variant="outline"
                onClick={handleClose}
                disabled={isSubmitting}
                className="border-gray-600"
              >
                Cancel
              </Button>
              <Button
                onClick={handleSubmitURL}
                disabled={!name || !sourceURL || isSubmitting}
                className="bg-blue-600 hover:bg-blue-700"
              >
                {isSubmitting ? "Creating..." : "Fetch Image"}
              </Button>
            </DialogFooter>
          </TabsContent>
        </Tabs>
      </DialogContent>
    </Dialog>
  );
}
