import {
  useMutation,
  useQueryClient,
  type MutationFunction,
  type QueryKey,
} from "@tanstack/react-query";

export function useInvalidatingMutation<TData, TVariables>(
  mutationFn: MutationFunction<TData, TVariables>,
  invalidations: (variables: TVariables) => readonly QueryKey[],
) {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn,
    onSuccess: async (_result, variables) => {
      await Promise.all(
        invalidations(variables).map((queryKey) =>
          queryClient.invalidateQueries({ queryKey }),
        ),
      );
    },
  });
}
