// User API endpoints

import { api } from "./client";
import type { CreateUserRequest, User } from "@/types/api";

export const usersApi = {
  // Create the account record before starting the passkey ceremony.
  register(data: CreateUserRequest): Promise<User> {
    return api.post<User>("/api/users/register", data);
  },
};
