"use client";

import { useState, useRef, useEffect } from "react";
import { useVMLogs } from "@/lib/hooks";
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
import {
  AlertCircle,
  CheckCircle,
  Info,
  AlertTriangle,
  RefreshCw,
  Download,
  Clock,
  Pause,
} from "lucide-react";
import type { VMLogEntry, VMLogLevel, VMEventType } from "@/types/api";

interface LogViewerProps {
  vmId: string;
  className?: string;
}

const LOG_LEVEL_CONFIG: Record<
  VMLogLevel,
  { icon: React.ReactNode; className: string }
> = {
  debug: {
    icon: <Info className="h-4 w-4" />,
    className: "text-gray-400",
  },
  info: {
    icon: <CheckCircle className="h-4 w-4" />,
    className: "text-blue-400",
  },
  warning: {
    icon: <AlertTriangle className="h-4 w-4" />,
    className: "text-yellow-400",
  },
  error: {
    icon: <AlertCircle className="h-4 w-4" />,
    className: "text-red-400",
  },
};

const EVENT_TYPE_CONFIG: Record<VMEventType, string> = {
  status_change: "bg-purple-500/20 text-purple-300 border-purple-500/30",
  operation: "bg-blue-500/20 text-blue-300 border-blue-500/30",
  qemu_output: "bg-gray-500/20 text-gray-300 border-gray-500/30",
  error: "bg-red-500/20 text-red-300 border-red-500/30",
  info: "bg-green-500/20 text-green-300 border-green-500/30",
};

export function LogViewer({ vmId, className }: LogViewerProps) {
  const [autoRefresh, setAutoRefresh] = useState(true);
  const [limit, setLimit] = useState(100);
  const scrollRef = useRef<HTMLDivElement>(null);

  const {
    data: logs,
    isLoading,
    isFetching,
    refetch,
  } = useVMLogs(vmId, {
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

  const getLogLevel = (entry: VMLogEntry): VMLogLevel => {
    return (entry.labels.level as VMLogLevel) || "info";
  };

  const getEventType = (entry: VMLogEntry): VMEventType => {
    return (entry.labels.event_type as VMEventType) || "info";
  };

  const downloadLogs = () => {
    if (!logs || logs.length === 0) return;

    const content = logs
      .map((log) => `${log.timestamp} [${log.labels.level || "info"}] ${log.message}`)
      .join("\n");

    const blob = new Blob([content], { type: "text/plain" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `vm-${vmId}-logs.txt`;
    a.click();
    URL.revokeObjectURL(url);
  };

  return (
    <Card className={`bg-gray-800 border-gray-700 ${className || ""}`}>
      <CardHeader className="flex flex-row items-center justify-between py-4">
        <CardTitle className="text-lg font-semibold text-gray-100">
          VM Logs
        </CardTitle>
        <div className="flex items-center gap-2">
          {/* Limit selector */}
          <Select
            value={String(limit)}
            onValueChange={(v) => setLimit(Number(v))}
          >
            <SelectTrigger className="w-[100px] bg-gray-700 border-gray-600">
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
            className={`border-gray-600 ${
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
            className="border-gray-600"
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
            className="border-gray-600"
          >
            <Download className="h-4 w-4" />
          </Button>
        </div>
      </CardHeader>
      <CardContent className="p-0">
        {/* Polling indicator */}
        {autoRefresh && (
          <div className="flex items-center gap-2 px-4 py-2 bg-green-900/10 border-b border-gray-700">
            <div className="h-2 w-2 rounded-full bg-green-500 animate-pulse" />
            <span className="text-xs text-green-400">
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
            <div className="flex items-center justify-center h-full text-gray-400">
              Loading logs...
            </div>
          ) : !logs || logs.length === 0 ? (
            <div className="flex flex-col items-center justify-center h-full text-gray-400 gap-2">
              <Info className="h-8 w-8" />
              <span>No logs available</span>
              <span className="text-xs text-gray-500">
                Logs will appear here when VM operations are performed
              </span>
            </div>
          ) : (
            <table className="w-full">
              <tbody>
                {logs.map((log, idx) => {
                  const level = getLogLevel(log);
                  const eventType = getEventType(log);
                  const levelConfig = LOG_LEVEL_CONFIG[level];
                  const eventTypeClass = EVENT_TYPE_CONFIG[eventType];

                  return (
                    <tr
                      key={`${log.timestamp}-${idx}`}
                      className="hover:bg-gray-700/50 border-b border-gray-800"
                    >
                      <td className="px-3 py-2 text-gray-500 whitespace-nowrap align-top">
                        {formatTimestamp(log.timestamp)}
                      </td>
                      <td className="px-2 py-2 align-top">
                        <span className={levelConfig.className}>
                          {levelConfig.icon}
                        </span>
                      </td>
                      <td className="px-2 py-2 align-top">
                        <Badge
                          variant="outline"
                          className={`text-xs ${eventTypeClass}`}
                        >
                          {eventType.replace("_", " ")}
                        </Badge>
                      </td>
                      <td className="px-2 py-2 align-top">
                        {log.labels.source && (
                          <span className="text-xs text-gray-500">
                            [{log.labels.source}]
                          </span>
                        )}
                      </td>
                      <td
                        className={`px-2 py-2 break-words ${levelConfig.className}`}
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
