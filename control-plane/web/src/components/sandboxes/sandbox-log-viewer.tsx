"use client";

import { useState } from "react";
import { Badge } from "@/components/ui/badge";
import { LogViewerShell } from "@/components/ui/log-viewer-shell";
import { useSandboxLogs } from "@/lib/hooks";
import type { SandboxLogEntry, SandboxLogStream } from "@/types/api";

interface SandboxLogViewerProps {
  sandboxId: string;
  className?: string;
}

const STREAM_BADGE_CLASS: Record<SandboxLogStream, string> = {
  stdout: "bg-gray-500/20 text-foreground/80 border-gray-500/30",
  stderr: "bg-amber-500/20 text-amber-700 border-amber-500/30",
};

function getStream(entry: SandboxLogEntry): SandboxLogStream {
  return entry.labels.stream === "stderr" ? "stderr" : "stdout";
}

function renderRow(log: SandboxLogEntry) {
  const stream = getStream(log);

  return (
    <>
      <td className="px-2 py-2 align-top">
        <Badge
          variant="outline"
          className={`text-xs ${STREAM_BADGE_CLASS[stream]}`}
        >
          {stream}
        </Badge>
      </td>
      <td
        className={`px-2 py-2 break-words w-full ${
          stream === "stderr" ? "text-amber-700" : "text-foreground/90"
        }`}
      >
        {log.message}
      </td>
    </>
  );
}

export function SandboxLogViewer({
  sandboxId,
  className,
}: SandboxLogViewerProps) {
  const [limit, setLimit] = useState(100);
  const [autoRefresh, setAutoRefresh] = useState(true);
  const query = useSandboxLogs(
    sandboxId,
    { limit, direction: "backward" },
    autoRefresh
  );

  return (
    <LogViewerShell
      title="Sandbox Logs"
      query={query}
      limit={limit}
      onLimitChange={setLimit}
      renderRow={renderRow}
      formatDownloadLine={(log) =>
        `${log.timestamp} [${getStream(log)}] ${log.message}`
      }
      emptyStateMessage={
        <>
          Workload stdout and stderr will appear here while the sandbox runs
        </>
      }
      downloadFilename={`sandbox-${sandboxId}-logs.txt`}
      autoRefresh={autoRefresh}
      onAutoRefreshChange={setAutoRefresh}
      className={className}
    />
  );
}
