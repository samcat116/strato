import { Badge } from "@/components/ui/badge";
import type { SVIDType } from "@/types/api";

const config: Record<SVIDType, { label: string; className: string }> = {
  x509: {
    label: "x509",
    className: "bg-blue-500/15 text-blue-600 dark:text-blue-400 border-blue-500/25",
  },
  jwt: {
    label: "jwt",
    className: "bg-purple-500/15 text-purple-600 dark:text-purple-400 border-purple-500/25",
  },
};

/** A small monospace badge for an SVID kind (x509 / jwt). */
export function SVIDBadge({ type }: { type: SVIDType }) {
  const { label, className } = config[type];
  return (
    <Badge
      variant="outline"
      className={`font-mono text-[10px] leading-none px-1.5 py-0.5 ${className}`}
    >
      {label}
    </Badge>
  );
}
