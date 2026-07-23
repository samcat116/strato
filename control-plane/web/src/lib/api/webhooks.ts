// Webhook subscription API client.
//
// Org-scoped webhook management: subscriptions that receive signed HTTP POST
// notifications for platform events (operations, VM state changes, agents,
// quotas). Listing is open to org members; mutations require org admin.
import { api } from "./client";
import type {
  CreateWebhookRequest,
  UpdateWebhookRequest,
  WebhookDelivery,
  WebhookSubscription,
  WebhookWithSecret,
} from "@/types/api";

const base = (orgId: string) => `/api/organizations/${orgId}/webhooks`;

export const webhooksApi = {
  list(orgId: string): Promise<WebhookSubscription[]> {
    return api.get<WebhookSubscription[]>(base(orgId));
  },

  /** The response carries the signing secret — shown once, stored hashed. */
  create(orgId: string, data: CreateWebhookRequest): Promise<WebhookWithSecret> {
    return api.post<WebhookWithSecret>(base(orgId), data);
  },

  get(orgId: string, webhookId: string): Promise<WebhookSubscription> {
    return api.get<WebhookSubscription>(`${base(orgId)}/${webhookId}`);
  },

  update(
    orgId: string,
    webhookId: string,
    data: UpdateWebhookRequest
  ): Promise<WebhookSubscription> {
    return api.put<WebhookSubscription>(`${base(orgId)}/${webhookId}`, data);
  },

  remove(orgId: string, webhookId: string): Promise<void> {
    return api.delete<void>(`${base(orgId)}/${webhookId}`);
  },

  /** Invalidates the previous secret. The new one is only returned here. */
  rotateSecret(orgId: string, webhookId: string): Promise<WebhookWithSecret> {
    return api.post<WebhookWithSecret>(
      `${base(orgId)}/${webhookId}/rotate-secret`
    );
  },

  /** Enqueue a webhook.test delivery. 409 if the subscription is disabled. */
  sendTest(orgId: string, webhookId: string): Promise<WebhookDelivery> {
    return api.post<WebhookDelivery>(`${base(orgId)}/${webhookId}/test`);
  },

  /** Newest first. `limit` 1–200, default 50. */
  listDeliveries(
    orgId: string,
    webhookId: string,
    limit = 50
  ): Promise<WebhookDelivery[]> {
    return api.get<WebhookDelivery[]>(`${base(orgId)}/${webhookId}/deliveries`, {
      limit: String(limit),
    });
  },

  /** 409 if the delivery is still pending or the subscription is disabled. */
  redeliver(
    orgId: string,
    webhookId: string,
    deliveryId: string
  ): Promise<WebhookDelivery> {
    return api.post<WebhookDelivery>(
      `${base(orgId)}/${webhookId}/deliveries/${deliveryId}/redeliver`
    );
  },
};
