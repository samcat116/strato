"use client";

import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { ImageTable, UploadImageDialog } from "@/components/images";
import { useImages, useInvalidateImages } from "@/lib/hooks/use-images";
import { useProjectContext } from "@/providers";
import { HardDrive, Loader2, FolderPlus } from "lucide-react";

export default function ImagesPage() {
  // Images are scoped to the project selected in the header switcher.
  const {
    currentProject,
    projects,
    isLoading: projectsLoading,
  } = useProjectContext();

  const projectId = currentProject?.id || "";
  const { data: images, isLoading: imagesLoading } = useImages(
    projectId || undefined
  );
  const invalidateImages = useInvalidateImages(projectId);

  // Loading state
  if (projectsLoading) {
    return (
      <div className="container mx-auto py-6">
        <div className="flex items-center justify-center h-64">
          <Loader2 className="h-8 w-8 animate-spin text-blue-400" />
          <span className="ml-2 text-gray-400">Loading projects...</span>
        </div>
      </div>
    );
  }

  // No projects state
  if (projects.length === 0) {
    return (
      <div className="container mx-auto py-6 space-y-6">
        <div className="flex items-center gap-3">
          <HardDrive className="h-8 w-8 text-blue-400" />
          <div>
            <h1 className="text-2xl font-bold text-gray-100">Images</h1>
            <p className="text-sm text-gray-400">
              Manage disk images for virtual machines
            </p>
          </div>
        </div>

        <Card className="bg-gray-800 border-gray-700">
          <CardContent className="py-12">
            <div className="flex flex-col items-center justify-center text-center">
              <FolderPlus className="h-12 w-12 text-gray-500 mb-4" />
              <h3 className="text-lg font-medium text-gray-100 mb-2">
                No Projects Found
              </h3>
              <p className="text-sm text-gray-400 max-w-md">
                You need to create a project before you can upload images.
                Projects help organize your resources within an organization.
              </p>
            </div>
          </CardContent>
        </Card>
      </div>
    );
  }

  return (
    <div className="container mx-auto py-6 space-y-6">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-3">
          <HardDrive className="h-8 w-8 text-blue-400" />
          <div>
            <h1 className="text-2xl font-bold text-gray-100">Images</h1>
            <p className="text-sm text-gray-400">
              Manage disk images for virtual machines
            </p>
          </div>
        </div>
        {projectId && (
          <UploadImageDialog projectId={projectId} onSuccess={invalidateImages} />
        )}
      </div>

      <Card className="bg-gray-800 border-gray-700">
        <CardHeader>
          <CardTitle className="text-gray-100">
            {currentProject
              ? `Images in ${currentProject.name}`
              : "Images"}
          </CardTitle>
        </CardHeader>
        <CardContent>
          <ImageTable
            images={images || []}
            projectId={projectId}
            isLoading={imagesLoading}
            onRefresh={invalidateImages}
          />
        </CardContent>
      </Card>
    </div>
  );
}
