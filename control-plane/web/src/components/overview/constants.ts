import type { AgentStatus, VMStatus } from "@/types/api";

// Chart + status palette from the Strato redesign (Overview.dc.html).
export const CHART_CPU = "#3c87dd";
export const CHART_MEMORY = "#a06fd4";
export const STATUS_GREEN = "#16a34a";
export const STATUS_AMBER = "#d97706";
export const STATUS_RED = "#dc2626";
export const STATUS_GRAY = "#b8b8b8";

export const agentStatusColors: Record<AgentStatus, string> = {
  online: STATUS_GREEN,
  connecting: STATUS_AMBER,
  error: STATUS_RED,
  offline: STATUS_GRAY,
};

export const vmStatusDots: Record<VMStatus, string> = {
  Running: STATUS_GREEN,
  Starting: CHART_CPU,
  Stopping: STATUS_AMBER,
  Paused: STATUS_AMBER,
  Shutdown: STATUS_GRAY,
  Created: STATUS_GRAY,
  Unknown: STATUS_GRAY,
  Error: STATUS_RED,
};

export const vmStatusBadges: Record<VMStatus, { label: string; bg: string; fg: string }> = {
  Running: { label: "Running", bg: "#ecfdf3", fg: "#027a48" },
  Starting: { label: "Starting", bg: "#eff6ff", fg: "#1d4ed8" },
  Stopping: { label: "Stopping", bg: "#fef7e6", fg: "#b45309" },
  Paused: { label: "Paused", bg: "#fef7e6", fg: "#b45309" },
  Shutdown: { label: "Stopped", bg: "#f2f2f2", fg: "#525252" },
  Created: { label: "Created", bg: "#f2f2f2", fg: "#525252" },
  Unknown: { label: "Unknown", bg: "#f2f2f2", fg: "#525252" },
  Error: { label: "Error", bg: "#fef1f1", fg: "#b42318" },
};

export function formatBytes(bytes: number): string {
  const gib = bytes / 1024 ** 3;
  if (gib >= 1024) return `${(gib / 1024).toFixed(1)} TiB`;
  return `${Math.round(gib)} GiB`;
}

/** Compact age like "12d", "3h", "45m" from an ISO timestamp. */
export function formatAge(iso: string): string {
  const ms = Date.now() - new Date(iso).getTime();
  if (Number.isNaN(ms) || ms < 0) return "—";
  const minutes = Math.floor(ms / 60_000);
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h`;
  return `${Math.floor(hours / 24)}d`;
}

export function createdWithinLastDay(iso: string): boolean {
  const age = Date.now() - new Date(iso).getTime();
  return age >= 0 && age < 24 * 60 * 60 * 1000;
}

export function reservedPercent(total: number, available: number): number {
  if (total <= 0) return 0;
  const used = Math.max(0, total - available);
  return Math.min(100, Math.round((used / total) * 100));
}
