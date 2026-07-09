import { cn } from "@/lib/utils";

export type KpiTone = "positive" | "warning" | "negative" | "neutral";

const toneClasses: Record<KpiTone, string> = {
  positive: "text-emerald-600",
  warning: "text-amber-700",
  negative: "text-red-600",
  neutral: "text-muted-foreground",
};

interface KpiCardProps {
  label: string;
  value: string;
  unit?: string;
  sub: string;
  tone?: KpiTone;
}

export function KpiCard({ label, value, unit, sub, tone = "neutral" }: KpiCardProps) {
  return (
    <div className="rounded-[11px] border border-border bg-card px-4 py-[15px]">
      <div className="text-[11px] font-semibold uppercase tracking-[0.4px] text-muted-foreground">
        {label}
      </div>
      <div className="mb-2 mt-1.5 flex items-baseline gap-0.5">
        <span className="font-mono text-[25px] font-bold leading-none">{value}</span>
        {unit && (
          <span className="font-mono text-[13px] text-muted-foreground">{unit}</span>
        )}
      </div>
      <div className={cn("truncate font-mono text-[11px]", toneClasses[tone])}>{sub}</div>
    </div>
  );
}
