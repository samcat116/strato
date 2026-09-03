import { vmsApi } from "@/lib/api/vms";
import type { VMLogEntry, VMLogsQueryParams } from "@/types/api";
import { makeResourceLogsHooks } from "./use-resource-logs";

export const useVMLogs = makeResourceLogsHooks<
  VMLogsQueryParams,
  VMLogEntry
>("vm-logs", (id, params) => vmsApi.getLogs(id, params));
