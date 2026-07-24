// User API endpoints

import { api } from "./client";
import type {
  AdminCreateUserRequest,
  AdminCreateUserResponse,
  CreateUserRequest,
  Page,
  UpdateUserRequest,
  User,
} from "@/types/api";
import { LIST_PAGE_LIMIT } from "@/types/api";

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
  list(): Promise<User[]> {
    return api
      .get<Page<User>>("/api/users", { limit: LIST_PAGE_LIMIT })
      .then((page) => page.items);
  },

  get(id: string): Promise<User> {
    return api.get<User>(`/api/users/${id}`);
  },

  update(id: string, data: UpdateUserRequest): Promise<User> {
    return api.put<User>(`/api/users/${id}`, data);
  },

  delete(id: string): Promise<void> {
    return api.delete(`/api/users/${id}`);
  },
};
