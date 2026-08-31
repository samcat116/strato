import { Badge } from "@/components/ui/badge";
const config: Record<string, { label: string; className: string }> = {
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
export function SVIDBadge({ type }: { type: string }) {
  const { label, className } = config[type] ?? {
    label: type,
    className: "bg-muted text-muted-foreground border-border",
  };
  return (
    <Badge
      variant="outline"
      className={`font-mono text-[10px] leading-none px-1.5 py-0.5 ${className}`}
    >
      {label}
    </Badge>
  );
}
