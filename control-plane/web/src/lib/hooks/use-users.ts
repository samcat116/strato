import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { usersApi } from "@/lib/api/users";
import { ApiError } from "@/lib/api/client";
import type { AdminCreateUserRequest, UpdateUserRequest } from "@/types/api";

// The endpoint filters per row on `user:read`, so a non-admin gets a
// one-element list of themselves rather than a 403. That is useless for the
// admin users page, so callers still gate on user.isSystemAdmin to keep the
// query from firing at all.
export function useUsers(enabled: boolean = true) {
  return useQuery({
    queryKey: ["users"],
    queryFn: () => usersApi.list(),
    enabled,
  });
}

export function useCreateUser() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (data: AdminCreateUserRequest) => usersApi.create(data),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["users"] });
    },
  });
}

export function useUpdateUser() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: ({ id, data }: { id: string; data: UpdateUserRequest }) =>
      usersApi.update(id, data),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["users"] });
    },
  });
}

export function useDeleteUser() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (id: string) => usersApi.delete(id),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["users"] });
    },
  });
}

export function userErrorMessage(error: unknown, fallback: string): string {
  if (error instanceof ApiError && error.status === 403) {
    return "You need system administrator rights to manage users.";
  }
  return error instanceof Error ? error.message : fallback;
}
