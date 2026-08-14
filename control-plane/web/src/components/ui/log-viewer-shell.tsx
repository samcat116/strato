"use client";

import { useEffect, useRef, type ReactNode } from "react";
import { Clock, Download, Info, Pause, RefreshCw } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";

interface LogEntry {
  timestamp: string;
}

interface LogQueryResult<Entry> {
  data: Entry[] | undefined;
  isLoading: boolean;
  isFetching: boolean;
  refetch: () => unknown;
}

interface LogViewerShellProps<Entry extends LogEntry> {
  title: string;
  query: LogQueryResult<Entry>;
  limit: number;
  onLimitChange: (limit: number) => void;
  renderRow: (entry: Entry, index: number) => ReactNode;
  formatDownloadLine: (entry: Entry) => string;
  emptyStateMessage: ReactNode;
  downloadFilename: string;
  autoRefresh: boolean;
  onAutoRefreshChange: (enabled: boolean) => void;
  className?: string;
}

export function LogViewerShell<Entry extends LogEntry>({
  title,
  query: { data: logs, isLoading, isFetching, refetch },
  limit,
  onLimitChange,
  renderRow,
  formatDownloadLine,
  emptyStateMessage,
  downloadFilename,
  autoRefresh,
  onAutoRefreshChange,
  className,
}: LogViewerShellProps<Entry>) {
  const scrollRef = useRef<HTMLDivElement>(null);

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

    const content = logs.map(formatDownloadLine).join("\n");

    const blob = new Blob([content], { type: "text/plain" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = downloadFilename;
    a.click();
    URL.revokeObjectURL(url);
  };

  return (
    <Card className={`bg-card border-border ${className || ""}`}>
      <CardHeader className="flex flex-row items-center justify-between py-4">
        <CardTitle className="text-lg font-semibold text-foreground">
          {title}
        </CardTitle>
        <div className="flex items-center gap-2">
          {/* Limit selector */}
          <Select
            value={String(limit)}
            onValueChange={(value) => onLimitChange(Number(value))}
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
            onClick={() => onAutoRefreshChange(!autoRefresh)}
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
            aria-label="Refresh logs"
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
            aria-label="Download logs"
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
                {emptyStateMessage}
              </span>
            </div>
          ) : (
            <table className="w-full">
              <tbody>
                {logs.map((log, index) => (
                  <tr
                    key={`${log.timestamp}-${index}`}
                    className="hover:bg-accent/60 border-b border-border"
                  >
                    <td className="px-3 py-2 text-muted-foreground whitespace-nowrap align-top">
                      {formatTimestamp(log.timestamp)}
                    </td>
                    {renderRow(log, index)}
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>
      </CardContent>
    </Card>
  );
}
