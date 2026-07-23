import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { webhooksApi } from "@/lib/api/webhooks";
import { ApiError } from "@/lib/api/client";
import type { CreateWebhookRequest, UpdateWebhookRequest } from "@/types/api";

export function useWebhooks(orgId: string, enabled = true) {
  return useQuery({
    queryKey: ["webhooks", orgId],
    queryFn: () => webhooksApi.list(orgId),
    enabled: enabled && !!orgId,
  });
}

export function useCreateWebhook(orgId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (data: CreateWebhookRequest) => webhooksApi.create(orgId, data),
    onSuccess: () =>
      queryClient.invalidateQueries({ queryKey: ["webhooks", orgId] }),
  });
}

export function useUpdateWebhook(orgId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({
      webhookId,
      data,
    }: {
      webhookId: string;
      data: UpdateWebhookRequest;
    }) => webhooksApi.update(orgId, webhookId, data),
    onSuccess: () =>
      queryClient.invalidateQueries({ queryKey: ["webhooks", orgId] }),
  });
}

export function useDeleteWebhook(orgId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (webhookId: string) => webhooksApi.remove(orgId, webhookId),
    onSuccess: () =>
      queryClient.invalidateQueries({ queryKey: ["webhooks", orgId] }),
  });
}

export function useRotateWebhookSecret(orgId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (webhookId: string) =>
      webhooksApi.rotateSecret(orgId, webhookId),
    onSuccess: () =>
      queryClient.invalidateQueries({ queryKey: ["webhooks", orgId] }),
  });
}

export function useSendTestWebhook(orgId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (webhookId: string) => webhooksApi.sendTest(orgId, webhookId),
    onSuccess: (_data, webhookId) =>
      queryClient.invalidateQueries({
        queryKey: ["webhook-deliveries", orgId, webhookId],
      }),
  });
}

/**
 * Recent deliveries for one subscription. Polls while enabled (i.e. while the
 * deliveries dialog is open) so pending retries and test sends resolve live.
 */
export function useWebhookDeliveries(
  orgId: string,
  webhookId: string | undefined,
  enabled = true
) {
  return useQuery({
    queryKey: ["webhook-deliveries", orgId, webhookId],
    queryFn: () => webhooksApi.listDeliveries(orgId, webhookId!),
    enabled: enabled && !!orgId && !!webhookId,
    refetchInterval: 5000,
  });
}

export function useRedeliverWebhookDelivery(orgId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({
      webhookId,
      deliveryId,
    }: {
      webhookId: string;
      deliveryId: string;
    }) => webhooksApi.redeliver(orgId, webhookId, deliveryId),
    onSuccess: (_data, { webhookId }) =>
      queryClient.invalidateQueries({
        queryKey: ["webhook-deliveries", orgId, webhookId],
      }),
  });
}

export function webhookErrorMessage(error: unknown, fallback: string): string {
  if (error instanceof ApiError && error.status === 403) {
    return "You need admin rights to manage webhooks.";
  }
  return error instanceof Error ? error.message : fallback;
}
