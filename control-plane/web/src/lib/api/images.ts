// Image API endpoints

import { api } from "./client";
import type {
  Image,
  ArtifactKind,
  CreateImageRequest,
  UpdateImageRequest,
  ImageStatusResponse,
} from "@/types/api";

export const imagesApi = {
  list(projectId: string): Promise<Image[]> {
    return api.get<Image[]>(`/api/projects/${projectId}/images`);
  },

  get(projectId: string, imageId: string): Promise<Image> {
    return api.get<Image>(`/api/projects/${projectId}/images/${imageId}`);
  },

  createFromURL(projectId: string, data: CreateImageRequest): Promise<Image> {
    return api.post<Image>(`/api/projects/${projectId}/images`, data);
  },

  // Creates a metadata-only image shell (no artifacts yet). Used as the first
  // step of registering a multi-artifact image such as a Firecracker
  // kernel+rootfs image, whose artifacts are uploaded afterwards.
  createEmpty(
    projectId: string,
    data: Omit<CreateImageRequest, "sourceURL">
  ): Promise<Image> {
    return api.post<Image>(`/api/projects/${projectId}/images`, data);
  },

  // Registers (or replaces) a single typed artifact on an existing image.
  uploadArtifact(
    projectId: string,
    imageId: string,
    kind: ArtifactKind,
    file: File,
    onProgress?: (progress: number) => void
  ): Promise<Image> {
    const formData = new FormData();
    formData.append("kind", kind);
    formData.append("file", file);

    return new Promise((resolve, reject) => {
      const xhr = new XMLHttpRequest();
      xhr.open(
        "POST",
        `/api/projects/${projectId}/images/${imageId}/artifacts`
      );
      xhr.withCredentials = true;

      xhr.upload.onprogress = (event) => {
        if (event.lengthComputable && onProgress) {
          onProgress(Math.round((event.loaded / event.total) * 100));
        }
      };

      xhr.onload = () => {
        if (xhr.status >= 200 && xhr.status < 300) {
          try {
            resolve(JSON.parse(xhr.responseText));
          } catch {
            reject(new Error("Invalid response format"));
          }
        } else {
          try {
            const error = JSON.parse(xhr.responseText);
            reject(new Error(error.reason || error.message || "Upload failed"));
          } catch {
            reject(new Error(`Upload failed with status ${xhr.status}`));
          }
        }
      };

      xhr.onerror = () => reject(new Error("Network error during upload"));
      xhr.send(formData);
    });
  },

  // Registers a typed artifact to be fetched from a URL in the background. The
  // artifact starts `pending` and becomes `ready` once the download completes.
  fetchArtifact(
    projectId: string,
    imageId: string,
    kind: ArtifactKind,
    sourceURL: string
  ): Promise<Image> {
    return api.post<Image>(
      `/api/projects/${projectId}/images/${imageId}/artifacts/fetch`,
      { kind, sourceURL }
    );
  },

  deleteArtifact(
    projectId: string,
    imageId: string,
    kind: ArtifactKind
  ): Promise<Image> {
    return api.delete<Image>(
      `/api/projects/${projectId}/images/${imageId}/artifacts/${kind}`
    );
  },

  async upload(
    projectId: string,
    file: File,
    metadata: Omit<CreateImageRequest, "sourceURL">,
    onProgress?: (progress: number) => void
  ): Promise<Image> {
    const formData = new FormData();
    formData.append("file", file);
    formData.append("name", metadata.name);
    if (metadata.description) {
      formData.append("description", metadata.description);
    }
    if (metadata.architecture) {
      formData.append("architecture", metadata.architecture);
    }
    if (metadata.defaultCpu) {
      formData.append("defaultCpu", metadata.defaultCpu.toString());
    }
    if (metadata.defaultMemory) {
      formData.append("defaultMemory", metadata.defaultMemory.toString());
    }
    if (metadata.defaultDisk) {
      formData.append("defaultDisk", metadata.defaultDisk.toString());
    }
    if (metadata.defaultCmdline) {
      formData.append("defaultCmdline", metadata.defaultCmdline);
    }

    // Use XMLHttpRequest for progress tracking
    return new Promise((resolve, reject) => {
      const xhr = new XMLHttpRequest();
      xhr.open("POST", `/api/projects/${projectId}/images`);

      // Include credentials (cookies)
      xhr.withCredentials = true;

      xhr.upload.onprogress = (event) => {
        if (event.lengthComputable && onProgress) {
          const progress = Math.round((event.loaded / event.total) * 100);
          onProgress(progress);
        }
      };

      xhr.onload = () => {
        if (xhr.status >= 200 && xhr.status < 300) {
          try {
            const response = JSON.parse(xhr.responseText);
            resolve(response);
          } catch {
            reject(new Error("Invalid response format"));
          }
        } else {
          try {
            const error = JSON.parse(xhr.responseText);
            reject(new Error(error.reason || error.message || "Upload failed"));
          } catch {
            reject(new Error(`Upload failed with status ${xhr.status}`));
          }
        }
      };

      xhr.onerror = () => {
        reject(new Error("Network error during upload"));
      };

      xhr.send(formData);
    });
  },

  update(
    projectId: string,
    imageId: string,
    data: UpdateImageRequest
  ): Promise<Image> {
    return api.put<Image>(`/api/projects/${projectId}/images/${imageId}`, data);
  },

  delete(projectId: string, imageId: string): Promise<void> {
    return api.delete(`/api/projects/${projectId}/images/${imageId}`);
  },

  getStatus(projectId: string, imageId: string): Promise<ImageStatusResponse> {
    return api.get<ImageStatusResponse>(
      `/api/projects/${projectId}/images/${imageId}/status`
    );
  },

  getDownloadURL(projectId: string, imageId: string): string {
    return `/api/projects/${projectId}/images/${imageId}/download`;
  },
};
