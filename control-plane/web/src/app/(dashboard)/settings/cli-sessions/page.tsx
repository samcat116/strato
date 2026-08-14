"use client";

import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { CLISessionTable } from "@/components/cli-sessions";
import { QueryErrorNotice } from "@/components/ui/query-error-notice";
import { useCLISessions } from "@/lib/hooks";

export default function CLISessionsPage() {
  const { data: sessions = [], isLoading, error, refetch } = useCLISessions();

  return (
    <div className="max-w-7xl mx-auto space-y-6">
      <div>
        <h2 className="text-2xl font-semibold text-foreground">CLI Sessions</h2>
        <p className="text-muted-foreground">
          Devices signed in with <code className="font-mono">strato login</code>.
          Revoking a session signs that device out immediately.
        </p>
      </div>

      <QueryErrorNotice
        resource="CLI sessions"
        error={error}
        hasData={sessions.length > 0}
        onRetry={() => void refetch()}
      />

      <Card className="bg-card border-border">
        <CardHeader>
          <CardTitle className="text-lg font-semibold text-foreground">
            Active Sessions
          </CardTitle>
        </CardHeader>
        <CardContent>
          <CLISessionTable sessions={sessions} isLoading={isLoading} />
        </CardContent>
      </Card>
    </div>
  );
}
