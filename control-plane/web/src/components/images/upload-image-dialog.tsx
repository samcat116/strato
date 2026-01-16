"use client";

import { useState, useRef } from "react";
import { Upload, Link as LinkIcon, X } from "lucide-react";
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
import { useCreateImageFromURL, useUploadImage } from "@/lib/hooks/use-images";

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
  const [sourceURL, setSourceURL] = useState("");
  const [selectedFile, setSelectedFile] = useState<File | null>(null);
  const [uploadProgress, setUploadProgress] = useState(0);
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const fileInputRef = useRef<HTMLInputElement>(null);

  const createFromURL = useCreateImageFromURL(projectId);
  const uploadImage = useUploadImage(projectId);

  const resetForm = () => {
    setName("");
    setDescription("");
    setSourceURL("");
    setSelectedFile(null);
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
            Upload a disk image or fetch from a URL.
          </DialogDescription>
        </DialogHeader>

        <Tabs defaultValue="upload" className="w-full">
          <TabsList className="grid w-full grid-cols-2 bg-gray-900">
            <TabsTrigger
              value="upload"
              className="data-[state=active]:bg-gray-700"
            >
              <Upload className="mr-2 h-4 w-4" />
              Upload
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
