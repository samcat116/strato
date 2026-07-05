"use client";

import { cn } from "@/lib/utils";

interface UsageBarProps {
  label: string;
  used: number;
  limit: number;
  unit?: string;
  /** Pre-computed percentage from the API; falls back to used/limit. */
  percent?: number;
  /** Fractions rendered on the numeric label (e.g. GB values). */
  decimals?: number;
}

function barColor(pct: number): string {
  if (pct >= 100) return "bg-red-500";
  if (pct >= 90) return "bg-orange-500";
  if (pct >= 75) return "bg-yellow-500";
  return "bg-blue-500";
}

function format(value: number, decimals: number): string {
  return decimals > 0
    ? value.toFixed(decimals)
    : Math.round(value).toString();
}

export function UsageBar({
  label,
  used,
  limit,
  unit,
  percent,
  decimals = 0,
}: UsageBarProps) {
  const pct =
    percent ?? (limit > 0 ? (used / limit) * 100 : used > 0 ? 100 : 0);
  const clamped = Math.min(100, Math.max(0, pct));

  return (
    <div className="space-y-1">
      <div className="flex items-center justify-between text-xs">
        <span className="text-gray-300">{label}</span>
        <span className="text-gray-400 tabular-nums">
          {format(used, decimals)} / {format(limit, decimals)}
          {unit ? ` ${unit}` : ""}
          <span className="ml-1 text-gray-500">({Math.round(pct)}%)</span>
        </span>
      </div>
      <div className="h-2 w-full overflow-hidden rounded-full bg-gray-700">
        <div
          className={cn("h-full rounded-full transition-all", barColor(pct))}
          style={{ width: `${clamped}%` }}
        />
      </div>
    </div>
  );
}
