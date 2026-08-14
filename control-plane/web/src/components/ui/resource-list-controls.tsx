"use client";

import { useEffect, useMemo, useState } from "react";
import { ChevronLeft, ChevronRight, Search } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";

const DEFAULT_PAGE_SIZE = 25;

function initialURLState() {
  if (typeof window === "undefined") return { query: "", page: 1 };
  const params = new URLSearchParams(window.location.search);
  const parsedPage = Number(params.get("page"));
  return {
    query: params.get("q") ?? "",
    page: Number.isInteger(parsedPage) && parsedPage > 0 ? parsedPage : 1,
  };
}

export function useResourceList<T>(
  items: T[],
  searchText: (item: T) => string,
  pageSize = DEFAULT_PAGE_SIZE
) {
  const [initial] = useState(() => initialURLState());
  const [query, setQueryState] = useState(initial.query);
  const [page, setPage] = useState(initial.page);
  const normalizedQuery = query.trim().toLocaleLowerCase();
  const filteredItems = useMemo(
    () =>
      normalizedQuery
        ? items.filter((item) =>
            searchText(item).toLocaleLowerCase().includes(normalizedQuery)
          )
        : items,
    [items, normalizedQuery, searchText]
  );
  const totalPages = Math.max(1, Math.ceil(filteredItems.length / pageSize));
  const currentPage = Math.min(page, totalPages);
  const pageItems = filteredItems.slice(
    (currentPage - 1) * pageSize,
    currentPage * pageSize
  );

  useEffect(() => {
    const url = new URL(window.location.href);
    if (query.trim()) url.searchParams.set("q", query.trim());
    else url.searchParams.delete("q");
    if (currentPage > 1) url.searchParams.set("page", String(currentPage));
    else url.searchParams.delete("page");
    window.history.replaceState(window.history.state, "", url);
  }, [query, currentPage]);

  return {
    query,
    setQuery: (value: string) => {
      setQueryState(value);
      setPage(1);
    },
    page: currentPage,
    setPage,
    pageItems,
    filteredCount: filteredItems.length,
    totalCount: items.length,
    totalPages,
    pageSize,
  };
}

interface ResourceListControlsProps {
  label: string;
  query: string;
  onQueryChange: (query: string) => void;
  page: number;
  onPageChange: (page: number) => void;
  totalPages: number;
  filteredCount: number;
  totalCount: number;
  pageSize: number;
}

export function ResourceListControls({
  label,
  query,
  onQueryChange,
  page,
  onPageChange,
  totalPages,
  filteredCount,
  totalCount,
  pageSize,
}: ResourceListControlsProps) {
  const first = filteredCount === 0 ? 0 : (page - 1) * pageSize + 1;
  const last = Math.min(page * pageSize, filteredCount);

  return (
    <div className="mb-4 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
      <div className="relative w-full sm:max-w-xs">
        <Search aria-hidden="true" className="absolute left-3 top-2.5 h-4 w-4 text-muted-foreground" />
        <Input
          type="search"
          aria-label={`Search ${label}`}
          placeholder={`Search ${label}…`}
          value={query}
          onChange={(event) => onQueryChange(event.target.value)}
          className="pl-9"
        />
      </div>
      <div className="flex items-center justify-between gap-3 text-sm text-muted-foreground sm:justify-end">
        <span aria-live="polite">
          {first}–{last} of {filteredCount}
          {filteredCount !== totalCount ? ` (${totalCount} total)` : ""}
        </span>
        <div className="flex gap-1">
          <Button
            type="button"
            variant="outline"
            size="icon"
            aria-label="Previous page"
            disabled={page <= 1}
            onClick={() => onPageChange(page - 1)}
          >
            <ChevronLeft className="h-4 w-4" />
          </Button>
          <Button
            type="button"
            variant="outline"
            size="icon"
            aria-label="Next page"
            disabled={page >= totalPages}
            onClick={() => onPageChange(page + 1)}
          >
            <ChevronRight className="h-4 w-4" />
          </Button>
        </div>
      </div>
    </div>
  );
}
