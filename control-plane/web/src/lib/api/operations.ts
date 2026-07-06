// Async VM operation endpoints (202 Accepted + polling)

import { api } from "./client";
import type { Operation } from "@/types/api";

export const operationsApi = {
  get(id: string): Promise<Operation> {
    return api.get<Operation>(`/api/operations/${id}`);
  },
};
