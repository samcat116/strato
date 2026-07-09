import type { Agent } from "@/types/api";
import { CHART_CPU, CHART_MEMORY, reservedPercent } from "./constants";

interface FleetCapacityChartProps {
  agents: Agent[];
}

/**
 * Per-agent reserved-capacity bars (CPU + memory). The control plane exposes
 * instantaneous capacity only — no metrics history — so this renders the
 * current reservation level per agent rather than a time series.
 */
export function FleetCapacityChart({ agents }: FleetCapacityChartProps) {
  if (agents.length === 0) {
    return (
      <div className="flex h-[150px] items-center justify-center text-[12.5px] text-muted-foreground">
        No agents connected yet
      </div>
    );
  }

  const sorted = [...agents].sort((a, b) => a.name.localeCompare(b.name));

  return (
    <div className="overflow-x-auto">
      <div className="relative h-[150px] min-w-full">
        {/* grid lines at 25/50/75% */}
        {[25, 50, 75].map((line) => (
          <div
            key={line}
            className="absolute inset-x-0 border-t border-muted"
            style={{ bottom: `${line}%` }}
          />
        ))}
        <div className="absolute inset-0 flex items-end justify-around gap-4 px-2">
          {sorted.map((agent) => {
            const cpu = reservedPercent(
              agent.resources.totalCPU,
              agent.resources.availableCPU
            );
            const memory = reservedPercent(
              agent.resources.totalMemory,
              agent.resources.availableMemory
            );
            return (
              <div
                key={agent.id}
                className="flex h-full min-w-9 items-end justify-center gap-[3px]"
                title={
                  agent.isOnline
                    ? `${agent.name} — CPU ${cpu}% · Memory ${memory}%`
                    : `${agent.name} — offline`
                }
              >
                {agent.isOnline ? (
                  <>
                    <div
                      className="w-3.5 rounded-t-sm"
                      style={{ height: `${Math.max(cpu, 1)}%`, background: CHART_CPU }}
                    />
                    <div
                      className="w-3.5 rounded-t-sm"
                      style={{ height: `${Math.max(memory, 1)}%`, background: CHART_MEMORY }}
                    />
                  </>
                ) : (
                  <div className="h-[3px] w-[31px] rounded-sm bg-border" />
                )}
              </div>
            );
          })}
        </div>
      </div>
      <div className="mt-2 flex items-start justify-around gap-4 px-2">
        {sorted.map((agent) => (
          <span
            key={agent.id}
            className={`min-w-9 truncate text-center font-mono text-[10px] ${
              agent.isOnline ? "text-muted-foreground" : "text-muted-foreground/50 line-through"
            }`}
            title={agent.name}
          >
            {agent.name}
          </span>
        ))}
      </div>
    </div>
  );
}
