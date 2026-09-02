import { errorMessage } from "@/lib/errors";
import { AlertTriangle } from "lucide-react";
import { Button } from "@/components/ui/button";

interface QueryErrorNoticeProps {
  resource: string;
  error: unknown;
  hasData: boolean;
  onRetry: () => void;
}

export function QueryErrorNotice({
  resource,
  error,
  hasData,
  onRetry,
}: QueryErrorNoticeProps) {
  if (!error) return null;

  const detail = errorMessage(error, "Request failed");

  return (
    <div
      role="alert"
      className="flex items-start justify-between gap-4 rounded-lg border border-amber-500/40 bg-amber-500/10 p-4"
    >
      <div className="flex gap-3">
        <AlertTriangle className="mt-0.5 h-5 w-5 shrink-0 text-amber-700" />
        <div>
          <p className="font-medium text-foreground">
            {hasData
              ? `Showing saved ${resource}; the latest refresh failed.`
              : `Unable to load ${resource}.`}
          </p>
          <p className="mt-1 text-sm text-muted-foreground">{detail}</p>
        </div>
      </div>
      <Button variant="outline" size="sm" onClick={onRetry}>
        Try again
      </Button>
    </div>
  );
}
