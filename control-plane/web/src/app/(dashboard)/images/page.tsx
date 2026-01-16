"use client";

import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { ImageTable, UploadImageDialog } from "@/components/images";
import { useImages, useInvalidateImages } from "@/lib/hooks/use-images";
import { useProjectsForOrganization } from "@/lib/hooks/use-projects";
import { useOrganization } from "@/providers/organization-provider";
import { HardDrive, Loader2, FolderPlus } from "lucide-react";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { useState, useMemo } from "react";

export default function ImagesPage() {
  const { currentOrg } = useOrganization();
  const [userSelectedProjectId, setUserSelectedProjectId] = useState<
    string | null
  >(null);

  // Fetch projects for the current organization
  const { data: projects, isLoading: projectsLoading } =
    useProjectsForOrganization(currentOrg?.id);

  // Derive the selected project ID: use user selection if set, otherwise default to first project
  const selectedProjectId = useMemo(() => {
    if (userSelectedProjectId) return userSelectedProjectId;
    if (projects && projects.length > 0) return projects[0].id;
    return null;
  }, [userSelectedProjectId, projects]);

  const projectId = selectedProjectId || "";
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
  if (!projects || projects.length === 0) {
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
        <div className="flex items-center gap-4">
          {projects.length > 1 && (
            <Select
              value={selectedProjectId || undefined}
              onValueChange={setUserSelectedProjectId}
            >
              <SelectTrigger className="w-48 bg-gray-900 border-gray-700 text-gray-100">
                <SelectValue placeholder="Select project" />
              </SelectTrigger>
              <SelectContent className="bg-gray-800 border-gray-700">
                {projects.map((project) => (
                  <SelectItem
                    key={project.id}
                    value={project.id}
                    className="text-gray-100 focus:bg-gray-700 focus:text-gray-100"
                  >
                    {project.name}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          )}
          {projectId && (
            <UploadImageDialog
              projectId={projectId}
              onSuccess={invalidateImages}
            />
          )}
        </div>
      </div>

      <Card className="bg-gray-800 border-gray-700">
        <CardHeader>
          <CardTitle className="text-gray-100">
            {projects.length === 1
              ? `Images in ${projects[0].name}`
              : "All Images"}
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
