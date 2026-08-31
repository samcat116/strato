"use client";

import { cn } from "@/lib/utils";
import type { Agent, Site } from "@/types/api";
import {
  STATUS_STYLES,
  displayStatus,
  siteMembers,
  type DisplayStatus,
} from "./site-model";

export function SiteFootprint({
  sites,
  agents,
  agentsKnown,
  canManage,
  onEdit,
}: {
  sites: Site[];
  agents: Agent[];
  agentsKnown: boolean;
  canManage: (site: Site) => boolean;
  onEdit: (site: Site) => void;
}) {
  const mappedSites = sites.filter(
    (site) =>
      typeof site.latitude === "number" && typeof site.longitude === "number"
  );
  const regionCount = new Set(
    sites.map((site) => site.regionCode).filter((region): region is string => !!region)
  ).size;

  return (
    <section className="overflow-hidden rounded-[11px] border border-border bg-card">
      <div className="flex flex-col gap-3 border-b border-border px-[18px] py-3.5 sm:flex-row sm:items-center">
        <div className="flex items-baseline gap-3">
          <h2 className="text-[13.5px] font-semibold">Global footprint</h2>
          <span className="font-mono text-[11.5px] text-muted-foreground">
            {sites.length} {sites.length === 1 ? "site" : "sites"} · {regionCount}{" "}
            {regionCount === 1 ? "region" : "regions"}
          </span>
        </div>
        <div className="flex-1" />
        <div className="flex flex-wrap gap-4 font-mono text-[11.5px] text-muted-foreground">
          {(Object.keys(STATUS_STYLES) as DisplayStatus[]).map((status) => (
            <span key={status} className="flex items-center gap-1.5">
              <span
                className="h-2.5 w-2.5 rounded-full"
                style={{ background: STATUS_STYLES[status].dot }}
              />
              {STATUS_STYLES[status].label}
            </span>
          ))}
        </div>
      </div>

      <div className="relative h-[330px] overflow-hidden bg-background/35 sm:h-[370px]">
        <svg
          className="absolute inset-0 h-full w-full text-slate-300 dark:text-slate-600"
          viewBox="0 0 1000 360"
          preserveAspectRatio="xMidYMid meet"
          aria-label="Site locations"
        >
          <defs>
            <pattern id="site-map-dots" width="14" height="14" patternUnits="userSpaceOnUse">
              <circle cx="3" cy="3" r="2.2" fill="currentColor" />
            </pattern>
          </defs>
          <g fill="url(#site-map-dots)" opacity="0.8" aria-hidden="true">
            <path d="M87 92 135 54l94 4 66 37 40 49-27 35-55 7-23 35-49-17-32-45-44-20z" />
            <path d="m253 207 45 15 28 45-13 76-28 11-31-62-18-51z" />
            <path d="m424 75 36-17 35 10-4 21-56 10z" />
            <path d="m459 111 65-13 48 31 6 62-31 98-38 35-34-57 15-56-37-51z" />
            <path d="m515 79 79-31 156 9 104 51-24 48-81 14-63-34-64 21-55-28z" />
            <path d="m789 242 56-19 55 31-9 49-65 13-43-31z" />
            <path d="m158 35 45-25 43 14-24 24-56 6z" />
          </g>

          {mappedSites.map((site) => {
            const members = siteMembers(site.id, agents);
            const status = displayStatus(site, members, agentsKnown);
            const x = ((site.longitude! + 180) / 360) * 1000;
            const y = ((90 - site.latitude!) / 180) * 360;
            const labelWidth = Math.max(74, site.name.length * 8 + 20);
            const labelTop = y > 320 ? -38 : 13;
            const editable = canManage(site);
            const edit = () => editable && onEdit(site);
            return (
              <g
                key={site.id}
                transform={`translate(${x} ${y})`}
                className={cn(editable ? "cursor-pointer" : "cursor-default")}
                role={editable ? "button" : undefined}
                tabIndex={editable ? 0 : undefined}
                aria-label={`${site.name}, ${STATUS_STYLES[status].label}${
                  editable ? ", edit site" : ""
                }`}
                onClick={edit}
                onKeyDown={(event) => {
                  if (editable && (event.key === "Enter" || event.key === " ")) {
                    event.preventDefault();
                    edit();
                  }
                }}
              >
                <circle
                  r="8"
                  fill={STATUS_STYLES[status].dot}
                  stroke="var(--card)"
                  strokeWidth="3"
                  className="drop-shadow-sm transition-transform"
                />
                <rect
                  x={-labelWidth / 2}
                  y={labelTop}
                  width={labelWidth}
                  height="23"
                  rx="5"
                  fill="var(--card)"
                  fillOpacity="0.9"
                  stroke="var(--border)"
                  strokeWidth="0.7"
                />
                <text
                  x="0"
                  y={labelTop + 16}
                  textAnchor="middle"
                  fill="var(--foreground)"
                  className="font-mono text-[11px] font-semibold"
                >
                  {site.name}
                </text>
              </g>
            );
          })}
        </svg>

        {mappedSites.length === 0 && (
          <div className="absolute inset-0 flex items-center justify-center px-6 text-center">
            <div>
              <div className="text-[13.5px] font-semibold">No mapped sites yet</div>
              <div className="mt-1 max-w-sm font-mono text-[11.5px] text-muted-foreground">
                Add latitude and longitude when editing a site to place it on the
                footprint.
              </div>
            </div>
          </div>
        )}

        {mappedSites.length > 0 && mappedSites.length < sites.length && (
          <div className="absolute bottom-3 right-4 rounded-md bg-card/90 px-2 py-1 font-mono text-[10.5px] text-muted-foreground shadow-sm">
            {sites.length - mappedSites.length} without coordinates
          </div>
        )}
      </div>
    </section>
  );
}
