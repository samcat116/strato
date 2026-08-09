import { AlertTriangle } from "lucide-react";
import type { ResourceConditions } from "@/types/api";

interface ConvergenceFailureAlertProps {
  conditions: ResourceConditions;
}

function formatErrorTime(value: string): string {
  const date = new Date(value);
  if (Number.isNaN(date.valueOf())) return value;
  return date.toISOString().replace("T", " ").replace(".000Z", " UTC");
}

/** Pure presentation over the workload detail response; it performs no fetch. */
export function ConvergenceFailureAlert({
  conditions,
}: ConvergenceFailureAlertProps) {
  const degraded = conditions.degraded;
  if (!degraded) return null;

  const isCurrent = degraded.sinceGeneration === conditions.targetGeneration;

  return (
    <div
      role="alert"
      className="flex gap-3 rounded-lg border border-destructive/40 bg-destructive/10 p-4 text-sm"
    >
      <AlertTriangle className="mt-0.5 h-5 w-5 shrink-0 text-destructive" />
      <div className="min-w-0 space-y-1">
        <p className="font-medium text-foreground">
          {isCurrent ? "Convergence failed" : "Previous convergence failure"}
        </p>
        <p className="break-words text-muted-foreground">{degraded.reason}</p>
        <p className="text-xs text-muted-foreground">
          Generation {degraded.sinceGeneration}
          {degraded.lastErrorAt
            ? ` · First observed ${formatErrorTime(degraded.lastErrorAt)}`
            : ""}
        </p>
      </div>
    </div>
  );
}
