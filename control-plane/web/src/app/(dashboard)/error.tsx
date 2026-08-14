"use client";

import { Button } from "@/components/ui/button";

export default function DashboardError({ reset }: { reset: () => void }) {
  return (
    <div className="flex min-h-[60vh] flex-col items-center justify-center gap-4 text-center">
      <div>
        <h1 className="text-xl font-semibold">This view is unavailable</h1>
        <p className="mt-2 text-sm text-muted-foreground">
          The rest of Strato is still available. Retry this view when ready.
        </p>
      </div>
      <Button onClick={reset}>Try again</Button>
    </div>
  );
}
