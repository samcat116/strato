// Image API endpoints

import { api } from "./client";
import { listAllPages } from "./pagination";
import type {
  Image,
  ArtifactKind,
  CreateImageRequest,
  ImageUploadForm,
  UpdateImageRequest,
} from "@/types/api";

export const imagesApi = {
  list(projectId: string, signal?: AbortSignal): Promise<Image[]> {
    return listAllPages<Image>(`/api/projects/${projectId}/images`, {}, signal);
  },

  get(projectId: string, imageId: string, signal?: AbortSignal): Promise<Image> {
    return api.get<Image>(`/api/projects/${projectId}/images/${imageId}`, undefined, signal);
  },

  createFromURL(projectId: string, data: CreateImageRequest): Promise<Image> {
    return api.post<Image>(`/api/projects/${projectId}/images`, data);
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
    metadata: Omit<ImageUploadForm, "file" | "name"> & { name: string },
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
    if (metadata.format) {
      formData.append("format", metadata.format);
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

  getDownloadURL(
    projectId: string,
    imageId: string,
    artifact: ArtifactKind
  ): string {
    return `/api/projects/${projectId}/images/${imageId}/download?artifact=${encodeURIComponent(artifact)}`;
  },
};
