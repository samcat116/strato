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
    <div className="rounded-lg border border-border bg-muted/50 px-4 py-3">
      <div className="text-2xl font-semibold text-foreground tabular-nums">
        {value}
      </div>
      <div className="text-xs text-muted-foreground">{label}</div>
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
        <p className="text-muted-foreground">No organization selected</p>
      </div>
    );
  }

  const stats = hierarchy?.stats;

  return (
    <div className="max-w-5xl mx-auto space-y-6">
      <div>
        <h2 className="text-2xl font-semibold text-foreground">
          Organization Hierarchy
        </h2>
        <p className="text-muted-foreground">
          Browse folders, projects, and resources
        </p>
      </div>

      {/* Search */}
      <div className="relative">
        <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-muted-foreground" />
        <Input
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder="Search folders, projects, and VMs..."
          className="bg-background border-border text-foreground pl-9 pr-9"
        />
        {isSearching && (
          <button
            onClick={() => setQuery("")}
            className="absolute right-3 top-1/2 -translate-y-1/2 text-muted-foreground hover:text-foreground"
            aria-label="Clear search"
          >
            <X className="h-4 w-4" />
          </button>
        )}
      </div>

      {isSearching ? (
        <Card className="bg-card border-border">
          <CardHeader>
            <CardTitle className="text-base font-semibold text-foreground flex items-center gap-2">
              Search Results
              {searching && (
                <Loader2 className="h-4 w-4 animate-spin text-muted-foreground" />
              )}
              {search && (
                <span className="text-sm font-normal text-muted-foreground">
                  ({search.totalResults})
                </span>
              )}
            </CardTitle>
          </CardHeader>
          <CardContent>
            {search && search.results.length === 0 && !searching ? (
              <p className="text-sm text-muted-foreground">
                No results for &quot;{query}&quot;.
              </p>
            ) : (
              <div className="space-y-1">
                {search?.results.map((result) => {
                  const href = resultHref(result);
                  const row = (
                    <div className="flex items-center justify-between gap-2 rounded-md px-3 py-2 hover:bg-accent/60 transition-colors">
                      <div className="min-w-0">
                        <div className="flex items-center gap-2">
                          <span className="text-sm text-foreground truncate">
                            {result.name}
                          </span>
                          <Badge
                            variant="outline"
                            className="border-input text-muted-foreground uppercase text-[10px]"
                          >
                            {result.type}
                          </Badge>
                        </div>
                        {result.path && (
                          <p className="text-xs text-muted-foreground truncate">
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
              <Stat label="Folders" value={stats.totalOUs} />
              <Stat label="Projects" value={stats.totalProjects} />
              <Stat label="VMs" value={stats.totalVMs} />
              <Stat label="Quotas" value={stats.totalQuotas} />
            </div>
          )}

          {/* Tree */}
          <Card className="bg-card border-border">
            <CardContent className="py-4">
              {isLoading ? (
                <div className="space-y-2">
                  <Skeleton className="h-6 w-1/2 bg-muted" />
                  <Skeleton className="h-6 w-2/3 bg-muted" />
                  <Skeleton className="h-6 w-1/3 bg-muted" />
                </div>
              ) : error || !hierarchy ? (
                <p className="text-sm text-muted-foreground py-6 text-center">
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
