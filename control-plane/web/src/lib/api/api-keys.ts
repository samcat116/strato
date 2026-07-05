// API key management endpoints

import { api } from "./client";
import type {
  APIKey,
  CreateAPIKeyRequest,
  CreateAPIKeyResponse,
} from "@/types/api";

export const apiKeysApi = {
  list(): Promise<APIKey[]> {
    return api.get<APIKey[]>("/api/api-keys");
  },

  create(data: CreateAPIKeyRequest): Promise<CreateAPIKeyResponse> {
    return api.post<CreateAPIKeyResponse>("/api/api-keys", data);
  },

  revoke(id: string): Promise<void> {
    return api.delete(`/api/api-keys/${id}`);
  },
};
