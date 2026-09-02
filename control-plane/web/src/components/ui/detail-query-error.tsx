import Link from "next/link";
import { AlertTriangle, ArrowLeft, RotateCw, SearchX } from "lucide-react";
import { Button } from "@/components/ui/button";
import { ApiError } from "@/lib/api/client";
import { errorMessage } from "@/lib/errors";

interface DetailQueryErrorProps {
  resourceName: string;
  backHref: string;
  backLabel: string;
  error: unknown;
  onRetry: () => void;
}

export function DetailQueryError({
  resourceName,
  backHref,
  backLabel,
  error,
  onRetry,
}: DetailQueryErrorProps) {
  const notFound = !error || (error instanceof ApiError && error.status === 404);
  const Icon = notFound ? SearchX : AlertTriangle;

  return (
    <div className="mx-auto max-w-4xl py-12 text-center">
      <div
        role={notFound ? undefined : "alert"}
        className="mx-auto flex max-w-lg flex-col items-center"
      >
        <Icon className="mb-4 h-10 w-10 text-muted-foreground" />
        <h2 className="text-xl font-semibold text-foreground">
          {notFound
            ? `${resourceName} not found`
            : `Unable to load ${resourceName.toLowerCase()}`}
        </h2>
        <p className="mt-2 text-sm text-muted-foreground">
          {notFound
            ? `This ${resourceName.toLowerCase()} may have been deleted, or you may no longer have access to it.`
            : errorMessage(
                error,
                `The ${resourceName.toLowerCase()} could not be loaded. Try again.`
              )}
        </p>
        <div className="mt-5 flex flex-wrap justify-center gap-2">
          {!notFound && (
            <Button type="button" onClick={onRetry}>
              <RotateCw className="h-4 w-4" />
              Try again
            </Button>
          )}
          <Button asChild variant="outline">
            <Link href={backHref}>
              <ArrowLeft className="h-4 w-4" />
              {backLabel}
            </Link>
          </Button>
        </div>
      </div>
    </div>
  );
}
