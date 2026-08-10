"use client";

import { useState } from "react";
import {
  AlertCircle,
  AlertTriangle,
  CheckCircle,
  Info,
} from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { LogViewerShell } from "@/components/ui/log-viewer-shell";
import { useVMLogs } from "@/lib/hooks";
import type { VMEventType, VMLogEntry, VMLogLevel } from "@/types/api";

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
    className: "text-muted-foreground",
  },
  info: {
    icon: <CheckCircle className="h-4 w-4" />,
    className: "text-blue-600",
  },
  warning: {
    icon: <AlertTriangle className="h-4 w-4" />,
    className: "text-yellow-700",
  },
  error: {
    icon: <AlertCircle className="h-4 w-4" />,
    className: "text-red-600",
  },
  // A line the backend could not classify — possibly an error from a newer
  // agent — must not masquerade as success; muted, not green.
  unknown: {
    icon: <Info className="h-4 w-4" />,
    className: "text-muted-foreground",
  },
};

const EVENT_TYPE_CONFIG: Record<VMEventType, string> = {
  status_change: "bg-purple-500/20 text-purple-700 border-purple-500/30",
  operation: "bg-blue-500/20 text-blue-700 border-blue-500/30",
  error: "bg-red-500/20 text-red-700 border-red-500/30",
  info: "bg-green-500/20 text-green-700 border-green-500/30",
  unknown: "bg-gray-500/20 text-muted-foreground border-gray-500/30",
};

function getLogLevel(entry: VMLogEntry): VMLogLevel {
  return (entry.labels.level as VMLogLevel) || "info";
}

function getEventType(entry: VMLogEntry): VMEventType {
  return (entry.labels.event_type as VMEventType) || "info";
}

function renderRow(log: VMLogEntry) {
  const level = getLogLevel(log);
  const eventType = getEventType(log);
  // Labels come from Loki as arbitrary strings (historical rows may carry
  // retired vocabulary), so fall back rather than crash on unknown values.
  const levelConfig = LOG_LEVEL_CONFIG[level] ?? LOG_LEVEL_CONFIG.unknown;
  const eventTypeClass =
    EVENT_TYPE_CONFIG[eventType] ?? EVENT_TYPE_CONFIG.unknown;

  return (
    <>
      <td className="px-2 py-2 align-top">
        <span className={levelConfig.className}>{levelConfig.icon}</span>
      </td>
      <td className="px-2 py-2 align-top">
        <Badge variant="outline" className={`text-xs ${eventTypeClass}`}>
          {eventType.replace("_", " ")}
        </Badge>
      </td>
      <td className="px-2 py-2 align-top">
        {log.labels.source && (
          <span className="text-xs text-muted-foreground">
            [{log.labels.source}]
          </span>
        )}
      </td>
      <td className={`px-2 py-2 break-words ${levelConfig.className}`}>
        {log.message}
      </td>
    </>
  );
}

export function LogViewer({ vmId, className }: LogViewerProps) {
  const [limit, setLimit] = useState(100);
  const query = useVMLogs(vmId, { limit, direction: "backward" });

  return (
    <LogViewerShell
      title="VM Logs"
      query={query}
      limit={limit}
      onLimitChange={setLimit}
      renderRow={renderRow}
      formatDownloadLine={(log) =>
        `${log.timestamp} [${log.labels.level || "info"}] ${log.message}`
      }
      emptyStateMessage="Logs will appear here when VM operations are performed"
      downloadFilename={`vm-${vmId}-logs.txt`}
      className={className}
    />
  );
}
