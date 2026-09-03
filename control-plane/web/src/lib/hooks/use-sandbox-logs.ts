import { sandboxesApi } from "@/lib/api/sandboxes";
import type { SandboxLogEntry, SandboxLogsQueryParams } from "@/types/api";
import { makeResourceLogsHooks } from "./use-resource-logs";

export const useSandboxLogs = makeResourceLogsHooks<
  SandboxLogsQueryParams,
  SandboxLogEntry
>("sandbox-logs", (id, params) => sandboxesApi.getLogs(id, params));
