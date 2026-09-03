import { useMutation } from "@tanstack/react-query";
import { toast } from "sonner";

interface WorkMutationOptions {
  onSuccess?: () => void;
  successMessage?: string;
}

/** Runs an already-bound async action with the standard page-level feedback. */
export function useWorkMutation({
  onSuccess,
  successMessage,
}: WorkMutationOptions = {}) {
  return useMutation<unknown, Error, () => Promise<unknown>>({
    mutationFn: (work) => work(),
    onSuccess: () => {
      onSuccess?.();
      if (successMessage) toast.success(successMessage);
    },
    onError: (error) => toast.error(error.message),
  });
}
