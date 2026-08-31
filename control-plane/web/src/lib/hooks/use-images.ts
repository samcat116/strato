import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { imagesApi } from "@/lib/api/images";
import type {
  ArtifactKind,
  CreateImageRequest,
  ImageUploadForm,
  UpdateImageRequest,
} from "@/types/api";

export function useImages(projectId: string | undefined) {
  return useQuery({
    queryKey: ["images", projectId],
    queryFn: ({ signal }) => (projectId ? imagesApi.list(projectId, signal) : Promise.resolve([])),
    enabled: !!projectId,
    refetchInterval: 5000, // Poll for status updates
  });
}

export function useImage(projectId: string | undefined, imageId: string | undefined) {
  return useQuery({
    queryKey: ["images", projectId, imageId],
    queryFn: ({ signal }) =>
      projectId && imageId
        ? imagesApi.get(projectId, imageId, signal)
        : Promise.reject("Missing projectId or imageId"),
    enabled: !!projectId && !!imageId,
    // Poll while the image or any artifact is still settling (e.g. a URL fetch
    // in progress) so the detail view reflects completion without a manual reload.
    refetchInterval: (query) => {
      const image = query.state.data;
      if (!image) return false;
      const settling =
        image.status !== "ready" && image.status !== "error";
      const artifactSettling = image.artifacts?.some(
        (a) => a.status === "pending" || a.status === "downloading"
      );
      return settling || artifactSettling ? 3000 : false;
    },
  });
}

export function useCreateImageFromURL(projectId: string) {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (data: CreateImageRequest) =>
      imagesApi.createFromURL(projectId, data),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["images", projectId] });
    },
  });
}

export function useUploadImage(projectId: string) {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: ({
      file,
      metadata,
      onProgress,
    }: {
      file: File;
      metadata: Omit<ImageUploadForm, "file" | "name"> & { name: string };
      onProgress?: (progress: number) => void;
    }) => imagesApi.upload(projectId, file, metadata, onProgress),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["images", projectId] });
    },
  });
}

export function useDeleteArtifact(projectId: string) {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: ({
      imageId,
      kind,
    }: {
      imageId: string;
      kind: ArtifactKind;
    }) => imagesApi.deleteArtifact(projectId, imageId, kind),
    onSuccess: (_, variables) => {
      queryClient.invalidateQueries({ queryKey: ["images", projectId] });
      queryClient.invalidateQueries({
        queryKey: ["images", projectId, variables.imageId],
      });
    },
  });
}

export function useUpdateImage(projectId: string) {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: ({
      imageId,
      data,
    }: {
      imageId: string;
      data: UpdateImageRequest;
    }) => imagesApi.update(projectId, imageId, data),
    onSuccess: (_, variables) => {
      queryClient.invalidateQueries({ queryKey: ["images", projectId] });
      queryClient.invalidateQueries({
        queryKey: ["images", projectId, variables.imageId],
      });
    },
  });
}

export function useDeleteImage(projectId: string) {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (imageId: string) => imagesApi.delete(projectId, imageId),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["images", projectId] });
    },
  });
}

export function useInvalidateImages(projectId: string) {
  const queryClient = useQueryClient();
  return () => queryClient.invalidateQueries({ queryKey: ["images", projectId] });
}
