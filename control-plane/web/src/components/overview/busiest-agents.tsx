import type { Agent } from "@/types/api";
import { STATUS_AMBER, reservedPercent } from "./constants";

interface BusiestAgentsProps {
  agents: Agent[];
}

export function BusiestAgents({ agents }: BusiestAgentsProps) {
  const busiest = agents
    .filter((a) => a.isOnline && a.resources.totalCPU > 0)
    .map((a) => ({
      id: a.id,
      name: a.name,
      pct: reservedPercent(a.resources.totalCPU, a.resources.availableCPU),
    }))
    .sort((a, b) => b.pct - a.pct)
    .slice(0, 3);

  if (busiest.length === 0) {
    return (
      <div className="text-[12.5px] text-muted-foreground">No online agents</div>
    );
  }

  return (
    <div className="space-y-2.5">
      {busiest.map((agent) => (
        <div key={agent.id} className="flex items-center gap-2.5">
          <span
            className="w-20 truncate font-mono text-[11.5px] text-foreground/75"
            title={agent.name}
          >
            {agent.name}
          </span>
          <div className="h-1.5 flex-1 overflow-hidden rounded bg-muted">
            <div
              className="h-full rounded"
              style={{
                width: `${agent.pct}%`,
                background: agent.pct >= 85 ? STATUS_AMBER : "var(--foreground)",
              }}
            />
          </div>
          <span className="w-8 text-right font-mono text-[11px] text-muted-foreground">
            {agent.pct}%
          </span>
        </div>
      ))}
    </div>
  );
}
