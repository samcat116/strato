// User API endpoints

import { api } from "./client";
import { listAllPages } from "./pagination";
import type {
  AdminCreateUserRequest,
  AdminCreateUserResponse,
  CreateUserRequest,
  UpdateUserRequest,
  User,
} from "@/types/api-contracts";

export const usersApi = {
  // Create the account record before starting the passkey ceremony.
  register(data: CreateUserRequest): Promise<User> {
    return api.post<User>("/api/users/register", data);
  },

  // System-admin only: create a user and mint a passkey-claim invite.
  create(data: AdminCreateUserRequest): Promise<AdminCreateUserResponse> {
    return api.post<AdminCreateUserResponse>("/api/users", data);
  },

  // System-admin only.
  list(signal?: AbortSignal): Promise<User[]> {
    return listAllPages<User>("/api/users", {}, signal);
  },

  update(id: string, data: UpdateUserRequest): Promise<User> {
    return api.put<User>(`/api/users/${id}`, data);
  },

  delete(id: string): Promise<void> {
    return api.delete(`/api/users/${id}`);
  },
};
