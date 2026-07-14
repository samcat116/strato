"use client";

import { useState, useRef, useEffect } from "react";
import { useSandboxLogs } from "@/lib/hooks";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Info, RefreshCw, Download, Clock, Pause } from "lucide-react";
import type { SandboxLogEntry, SandboxLogStream } from "@/types/api";

// Workload stdout/stderr viewer (backend issue #423), modeled on the VM
// LogViewer but with a stream badge instead of level/event-type columns.

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

export function SandboxLogViewer({
  sandboxId,
  className,
}: SandboxLogViewerProps) {
  const [autoRefresh, setAutoRefresh] = useState(true);
  const [limit, setLimit] = useState(100);
  const scrollRef = useRef<HTMLDivElement>(null);

  const {
    data: logs,
    isLoading,
    isFetching,
    refetch,
  } = useSandboxLogs(sandboxId, {
    limit,
    direction: "backward",
  });

  // Auto-scroll to bottom when new logs arrive
  useEffect(() => {
    if (scrollRef.current && autoRefresh && logs && logs.length > 0) {
      scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
    }
  }, [logs, autoRefresh]);

  const formatTimestamp = (timestamp: string) => {
    try {
      return new Date(timestamp).toLocaleString();
    } catch {
      return timestamp;
    }
  };

  const downloadLogs = () => {
    if (!logs || logs.length === 0) return;

    const content = logs
      .map((log) => `${log.timestamp} [${getStream(log)}] ${log.message}`)
      .join("\n");

    const blob = new Blob([content], { type: "text/plain" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `sandbox-${sandboxId}-logs.txt`;
    a.click();
    URL.revokeObjectURL(url);
  };

  return (
    <Card className={`bg-card border-border ${className || ""}`}>
      <CardHeader className="flex flex-row items-center justify-between py-4">
        <CardTitle className="text-lg font-semibold text-foreground">
          Sandbox Logs
        </CardTitle>
        <div className="flex items-center gap-2">
          {/* Limit selector */}
          <Select
            value={String(limit)}
            onValueChange={(v) => setLimit(Number(v))}
          >
            <SelectTrigger className="w-[100px] bg-muted border-input">
              <SelectValue placeholder="Limit" />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="50">50 logs</SelectItem>
              <SelectItem value="100">100 logs</SelectItem>
              <SelectItem value="200">200 logs</SelectItem>
              <SelectItem value="500">500 logs</SelectItem>
            </SelectContent>
          </Select>

          {/* Auto-refresh toggle */}
          <Button
            variant="outline"
            size="sm"
            onClick={() => setAutoRefresh(!autoRefresh)}
            className={`border-input ${
              autoRefresh ? "bg-green-900/20 border-green-700" : ""
            }`}
          >
            {autoRefresh ? (
              <>
                <Clock className="h-4 w-4 mr-1" />
                Live
              </>
            ) : (
              <>
                <Pause className="h-4 w-4 mr-1" />
                Paused
              </>
            )}
          </Button>

          {/* Manual refresh */}
          <Button
            variant="outline"
            size="sm"
            onClick={() => refetch()}
            disabled={isFetching}
            className="border-input"
          >
            <RefreshCw
              className={`h-4 w-4 ${isFetching ? "animate-spin" : ""}`}
            />
          </Button>

          {/* Download */}
          <Button
            variant="outline"
            size="sm"
            onClick={downloadLogs}
            disabled={!logs || logs.length === 0}
            className="border-input"
          >
            <Download className="h-4 w-4" />
          </Button>
        </div>
      </CardHeader>
      <CardContent className="p-0">
        {/* Polling indicator */}
        {autoRefresh && (
          <div className="flex items-center gap-2 px-4 py-2 bg-green-900/10 border-b border-border">
            <div className="h-2 w-2 rounded-full bg-green-500 animate-pulse" />
            <span className="text-xs text-green-600">
              Auto-refreshing every 5 seconds
            </span>
          </div>
        )}

        {/* Logs list */}
        <div
          ref={scrollRef}
          className="h-[400px] overflow-auto font-mono text-xs"
        >
          {isLoading ? (
            <div className="flex items-center justify-center h-full text-muted-foreground">
              Loading logs...
            </div>
          ) : !logs || logs.length === 0 ? (
            <div className="flex flex-col items-center justify-center h-full text-muted-foreground gap-2">
              <Info className="h-8 w-8" />
              <span>No logs available</span>
              <span className="text-xs text-muted-foreground">
                Workload stdout and stderr will appear here while the sandbox
                runs
              </span>
            </div>
          ) : (
            <table className="w-full">
              <tbody>
                {logs.map((log, idx) => {
                  const stream = getStream(log);

                  return (
                    <tr
                      key={`${log.timestamp}-${idx}`}
                      className="hover:bg-accent/60 border-b border-border"
                    >
                      <td className="px-3 py-2 text-muted-foreground whitespace-nowrap align-top">
                        {formatTimestamp(log.timestamp)}
                      </td>
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
                          stream === "stderr"
                            ? "text-amber-700"
                            : "text-foreground/90"
                        }`}
                      >
                        {log.message}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          )}
        </div>
      </CardContent>
    </Card>
  );
}
