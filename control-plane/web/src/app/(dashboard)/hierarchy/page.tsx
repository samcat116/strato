"use client";

import { useState } from "react";
import Link from "next/link";
import { Search, Loader2, X } from "lucide-react";
import { Input } from "@/components/ui/input";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { Badge } from "@/components/ui/badge";
import { HierarchyTree } from "@/components/hierarchy";
import { useHierarchy, useHierarchySearch } from "@/lib/hooks";
import { useOrganization } from "@/providers";
import type { HierarchySearchResult } from "@/types/api";

function resultHref(result: HierarchySearchResult): string | undefined {
  if (result.type === "vm") return `/vms/detail?id=${result.id}`;
  return undefined;
}

function Stat({ label, value }: { label: string; value: number | string }) {
  return (
    <div className="rounded-lg border border-gray-700 bg-gray-900/50 px-4 py-3">
      <div className="text-2xl font-semibold text-gray-100 tabular-nums">
        {value}
      </div>
      <div className="text-xs text-gray-400">{label}</div>
    </div>
  );
}

export default function HierarchyPage() {
  const { currentOrg } = useOrganization();
  const orgId = currentOrg?.id;

  const { data: hierarchy, isLoading, error } = useHierarchy(orgId);
  const [query, setQuery] = useState("");
  const { data: search, isFetching: searching } = useHierarchySearch(
    orgId,
    query
  );

  const isSearching = query.trim().length > 0;

  if (!orgId) {
    return (
      <div className="max-w-5xl mx-auto text-center py-12">
        <p className="text-gray-400">No organization selected</p>
      </div>
    );
  }

  const stats = hierarchy?.stats;

  return (
    <div className="max-w-5xl mx-auto space-y-6">
      <div>
        <h2 className="text-2xl font-semibold text-gray-100">
          Organization Hierarchy
        </h2>
        <p className="text-gray-400">
          Browse organizational units, projects, and resources
        </p>
      </div>

      {/* Search */}
      <div className="relative">
        <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-gray-500" />
        <Input
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder="Search units, projects, and VMs..."
          className="bg-gray-900 border-gray-700 text-gray-100 pl-9 pr-9"
        />
        {isSearching && (
          <button
            onClick={() => setQuery("")}
            className="absolute right-3 top-1/2 -translate-y-1/2 text-gray-500 hover:text-gray-200"
            aria-label="Clear search"
          >
            <X className="h-4 w-4" />
          </button>
        )}
      </div>

      {isSearching ? (
        <Card className="bg-gray-800 border-gray-700">
          <CardHeader>
            <CardTitle className="text-base font-semibold text-gray-100 flex items-center gap-2">
              Search Results
              {searching && (
                <Loader2 className="h-4 w-4 animate-spin text-gray-400" />
              )}
              {search && (
                <span className="text-sm font-normal text-gray-400">
                  ({search.totalResults})
                </span>
              )}
            </CardTitle>
          </CardHeader>
          <CardContent>
            {search && search.results.length === 0 && !searching ? (
              <p className="text-sm text-gray-500">
                No results for &quot;{query}&quot;.
              </p>
            ) : (
              <div className="space-y-1">
                {search?.results.map((result) => {
                  const href = resultHref(result);
                  const row = (
                    <div className="flex items-center justify-between gap-2 rounded-md px-3 py-2 hover:bg-gray-700/50 transition-colors">
                      <div className="min-w-0">
                        <div className="flex items-center gap-2">
                          <span className="text-sm text-gray-200 truncate">
                            {result.name}
                          </span>
                          <Badge
                            variant="outline"
                            className="border-gray-600 text-gray-400 uppercase text-[10px]"
                          >
                            {result.type}
                          </Badge>
                        </div>
                        {result.path && (
                          <p className="text-xs text-gray-500 truncate">
                            {result.path}
                          </p>
                        )}
                      </div>
                    </div>
                  );
                  return href ? (
                    <Link key={`${result.type}-${result.id}`} href={href}>
                      {row}
                    </Link>
                  ) : (
                    <div key={`${result.type}-${result.id}`}>{row}</div>
                  );
                })}
              </div>
            )}
          </CardContent>
        </Card>
      ) : (
        <>
          {/* Stats */}
          {stats && (
            <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
              <Stat label="Units" value={stats.totalOUs} />
              <Stat label="Projects" value={stats.totalProjects} />
              <Stat label="VMs" value={stats.totalVMs} />
              <Stat label="Quotas" value={stats.totalQuotas} />
            </div>
          )}

          {/* Tree */}
          <Card className="bg-gray-800 border-gray-700">
            <CardContent className="py-4">
              {isLoading ? (
                <div className="space-y-2">
                  <Skeleton className="h-6 w-1/2 bg-gray-700" />
                  <Skeleton className="h-6 w-2/3 bg-gray-700" />
                  <Skeleton className="h-6 w-1/3 bg-gray-700" />
                </div>
              ) : error || !hierarchy ? (
                <p className="text-sm text-gray-400 py-6 text-center">
                  Failed to load the organization hierarchy.
                </p>
              ) : (
                <HierarchyTree org={hierarchy.organization} />
              )}
            </CardContent>
          </Card>
        </>
      )}
    </div>
  );
}
