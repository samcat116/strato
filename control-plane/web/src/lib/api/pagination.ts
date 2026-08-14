import { api } from "./client";
import type { Page } from "@/types/api";
import { LIST_PAGE_LIMIT } from "@/types/api";

/**
 * Fetches every page for views that still render a complete client-side list.
 *
 * The guard against an empty, incomplete page matters: without it, a malformed
 * pagination response would spin forever and turn a recoverable API problem
 * into an unbounded request loop.
 */
export async function listAllPages<T>(
  endpoint: string,
  params: Record<string, string> = {},
  signal?: AbortSignal
): Promise<T[]> {
  const items: T[] = [];
  let offset = 0;

  while (true) {
    const page = await api.get<Page<T>>(endpoint, {
      ...params,
      limit: LIST_PAGE_LIMIT,
      offset: String(offset),
    }, signal);

    if (page.items.length === 0) {
      if (offset < page.total) {
        throw new Error(
          `Pagination stalled for ${endpoint}: received an empty page at offset ${offset} of ${page.total}`
        );
      }
      return items;
    }

    items.push(...page.items);
    offset += page.items.length;

    if (offset >= page.total) {
      return items;
    }
  }
}
