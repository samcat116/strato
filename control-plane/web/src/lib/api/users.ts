// User API endpoints

import { api } from "./client";
import type { CreateUserRequest, UpdateUserRequest, User } from "@/types/api";

export const usersApi = {
  // Create the account record before starting the passkey ceremony.
  register(data: CreateUserRequest): Promise<User> {
    return api.post<User>("/api/users/register", data);
  },

  // System-admin only.
  list(): Promise<User[]> {
    return api.get<User[]>("/api/users");
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
