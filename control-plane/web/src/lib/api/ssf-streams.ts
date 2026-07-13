// Shared Signals Framework (SSF) receiver stream API client.
//
// Org-scoped stream management plus transmitter-side actions (register,
// verify, status, poll). The push delivery endpoint itself is public and
// called by transmitters, not by this frontend.
import { api } from "./client";
import type {
  SSFStream,
  CreateSSFStreamRequest,
  UpdateSSFStreamRequest,
  RegisterSSFStreamResponse,
  SSFStreamStatus,
  SSFPollResult,
} from "@/types/api";

const base = (orgId: string) => `/api/organizations/${orgId}/ssf-streams`;

export const ssfStreamsApi = {
  list(orgId: string): Promise<SSFStream[]> {
    return api.get<SSFStream[]>(base(orgId));
  },

  create(orgId: string, data: CreateSSFStreamRequest): Promise<SSFStream> {
    return api.post<SSFStream>(base(orgId), data);
  },

  update(
    orgId: string,
    streamId: string,
    data: UpdateSSFStreamRequest
  ): Promise<SSFStream> {
    return api.put<SSFStream>(`${base(orgId)}/${streamId}`, data);
  },

  delete(orgId: string, streamId: string): Promise<void> {
    return api.delete<void>(`${base(orgId)}/${streamId}`);
  },

  /**
   * Create the stream at the transmitter. For push streams the response
   * carries the inbound bearer token — shown once, stored hashed.
   */
  register(orgId: string, streamId: string): Promise<RegisterSSFStreamResponse> {
    return api.post<RegisterSSFStreamResponse>(
      `${base(orgId)}/${streamId}/register`
    );
  },

  /** Ask the transmitter to send a verification event. */
  verify(orgId: string, streamId: string): Promise<void> {
    return api.post<void>(`${base(orgId)}/${streamId}/verify`);
  },

  /** Transmitter-side stream status. */
  status(orgId: string, streamId: string): Promise<SSFStreamStatus> {
    return api.get<SSFStreamStatus>(`${base(orgId)}/${streamId}/status`);
  },

  /** Drain a poll stream immediately. */
  pollNow(orgId: string, streamId: string): Promise<SSFPollResult> {
    return api.post<SSFPollResult>(`${base(orgId)}/${streamId}/poll`);
  },
};
