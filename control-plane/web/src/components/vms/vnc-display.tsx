"use client";

import { useEffect, useRef, useCallback } from "react";
import { Keyboard } from "lucide-react";
import { Button } from "@/components/ui/button";
import { useVNC } from "@/lib/hooks";

// The VM's graphics console (backend issue #566): noVNC rendering the guest's
// framebuffer, with keyboard and absolute-pointer input. The counterpart to
// console-terminal.tsx, which drives the same relay for the serial console.
//
// Loaded through next/dynamic with `ssr: false` by the caller — noVNC touches
// `document` while its module is evaluated.

interface VNCDisplayProps {
  vmId: string;
  className?: string;
  onConnected?: () => void;
  onDisconnected?: (reason?: string) => void;
}

export function VNCDisplay({
  vmId,
  className,
  onConnected,
  onDisconnected,
}: VNCDisplayProps) {
  const containerRef = useRef<HTMLDivElement>(null);

  const handleError = useCallback((error: Error) => {
    console.error("Graphics console error:", error);
  }, []);

  const { connect, disconnect, sendCtrlAltDel, isConnected, isConnecting, error } =
    useVNC({
      vmId,
      onConnected,
      onDisconnected,
      onError: handleError,
    });

  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;

    connect(container);
    return disconnect;
  }, [vmId, connect, disconnect]);

  return (
    <div className={`relative bg-[#111827] ${className || ""}`}>
      <div className="absolute top-2 right-2 z-10 flex items-center gap-3">
        {/* A browser intercepts Ctrl+Alt+Del before the guest ever sees it, so
            it has to be sent out of band. */}
        {isConnected && (
          <Button
            variant="secondary"
            size="sm"
            className="h-7 gap-1.5 text-xs"
            onClick={sendCtrlAltDel}
          >
            <Keyboard className="h-3.5 w-3.5" />
            Ctrl+Alt+Del
          </Button>
        )}
        <div className="flex items-center gap-2">
          <div
            className={`h-2 w-2 rounded-full ${
              isConnected
                ? "bg-green-500"
                : isConnecting
                  ? "bg-yellow-500 animate-pulse"
                  : "bg-red-500"
            }`}
          />
          <span className="text-xs text-muted-foreground">
            {isConnected
              ? "Connected"
              : isConnecting
                ? "Connecting..."
                : "Disconnected"}
          </span>
        </div>
      </div>

      {/* The server's reason is the actionable part — "created without a
          display", "agent too old" — so show it rather than a generic failure. */}
      {error && !isConnected && (
        <div className="absolute inset-0 z-10 flex items-center justify-center p-6">
          <p className="max-w-md text-center text-sm text-red-400">{error.message}</p>
        </div>
      )}

      {/* noVNC appends its canvas here. */}
      <div
        ref={containerRef}
        className="flex h-full w-full items-center justify-center"
        style={{ minHeight: "400px" }}
      />
    </div>
  );
}
