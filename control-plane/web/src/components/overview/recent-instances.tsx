import Link from "next/link";
import type { Agent, VM } from "@/types/api";
import { formatAge, vmStatusBadges, vmStatusDots } from "./constants";

interface RecentInstancesProps {
  vms: VM[];
  agents: Agent[];
}

const GRID = "grid grid-cols-[12px_1.6fr_1fr_1fr_1fr_0.6fr_0.8fr] items-center gap-3.5";

export function RecentInstances({ vms, agents }: RecentInstancesProps) {
  // Case-insensitive: hypervisorId is stored as text and may not match the
  // agent UUID's casing.
  const agentNames = new Map(agents.map((a) => [a.id.toLowerCase(), a.name]));
  const recent = [...vms]
    .sort(
      (a, b) => new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime()
    )
    .slice(0, 6);

  return (
    <div className="overflow-hidden rounded-[11px] border border-border bg-card">
      <div className="flex items-center border-b border-muted px-4 py-3">
        <span className="text-[13.5px] font-semibold">Recent instances</span>
        <div className="flex-1" />
        <Link
          href="/vms"
          className="text-[12.5px] text-[#3c87dd] transition-colors hover:text-[#2a6bc0]"
        >
          View all {vms.length} →
        </Link>
      </div>

      {recent.length === 0 ? (
        <div className="px-4 py-8 text-center text-[12.5px] text-muted-foreground">
          No instances yet — create one to get started.
        </div>
      ) : (
        <>
          <div
            className={`${GRID} border-b border-muted px-4 py-2 text-[10.5px] font-semibold uppercase tracking-[0.4px] text-muted-foreground`}
          >
            <span />
            <span>Name</span>
            <span>Agent</span>
            <span>Image</span>
            <span>Specs</span>
            <span>Age</span>
            <span>Status</span>
          </div>
          {recent.map((vm) => {
            const badge = vmStatusBadges[vm.status] ?? vmStatusBadges.Unknown;
            const agentName = vm.hypervisorId
              ? (agentNames.get(vm.hypervisorId.toLowerCase()) ?? "—")
              : "—";
            return (
              <Link
                key={vm.id}
                href={`/vms/detail?id=${vm.id}`}
                className={`${GRID} border-b border-muted px-4 py-2.5 transition-colors last:border-b-0 hover:bg-background/60`}
              >
                <span
                  className="h-2 w-2 rounded-full"
                  style={{ background: vmStatusDots[vm.status] ?? vmStatusDots.Unknown }}
                />
                <span className="truncate font-mono text-[13px] font-semibold">
                  {vm.name}
                </span>
                <span className="truncate font-mono text-[12.5px] text-muted-foreground">
                  {agentName}
                </span>
                <span className="truncate font-mono text-[12.5px] text-muted-foreground">
                  {vm.image || "—"}
                </span>
                <span className="truncate font-mono text-[11px] text-muted-foreground">
                  {vm.cpu} vCPU · {vm.memoryFormatted}
                </span>
                <span className="font-mono text-[12.5px] text-muted-foreground">
                  {formatAge(vm.createdAt)}
                </span>
                <span
                  className="justify-self-start rounded-full px-2.5 py-0.5 text-[10.5px] font-semibold"
                  style={{ background: badge.bg, color: badge.fg }}
                >
                  {badge.label}
                </span>
              </Link>
            );
          })}
        </>
      )}
    </div>
  );
}
