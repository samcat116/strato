import { vmsApi } from "@/lib/api/vms";
import type { VMLogEntry, VMLogsQueryParams } from "@/types/api";
import { makeResourceLogsHooks } from "./use-resource-logs";

const { useLogs, useInvalidateLogs } = makeResourceLogsHooks<
  VMLogsQueryParams,
  VMLogEntry
>("vm-logs", (id, params) => vmsApi.getLogs(id, params));

export { useLogs as useVMLogs, useInvalidateLogs as useInvalidateVMLogs };
