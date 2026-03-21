"use client";

import { useEffect, useRef, useCallback } from "react";
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { useConsole } from "@/lib/hooks";
import "@xterm/xterm/css/xterm.css";

interface ConsoleTerminalProps {
  vmId: string;
  className?: string;
  onConnected?: () => void;
  onDisconnected?: (reason?: string) => void;
}

export function ConsoleTerminal({
  vmId,
  className,
  onConnected,
  onDisconnected,
}: ConsoleTerminalProps) {
  const terminalRef = useRef<HTMLDivElement>(null);
  const termInstance = useRef<Terminal | null>(null);
  const fitAddonRef = useRef<FitAddon | null>(null);

  const handleError = useCallback((error: Error) => {
    console.error("Console error:", error);
  }, []);

  const { connect, disconnect, isConnected, isConnecting } = useConsole({
    vmId,
    onConnected,
    onDisconnected,
    onError: handleError,
  });

  useEffect(() => {
    if (!terminalRef.current || termInstance.current) return;

    const term = new Terminal({
      theme: {
        background: "#111827",
        foreground: "#f3f4f6",
        cursor: "#60a5fa",
        cursorAccent: "#1f2937",
        selectionBackground: "#374151",
      },
      fontFamily: "ui-monospace, monospace",
      fontSize: 14,
      cursorBlink: true,
      convertEol: true,
    });

    const fitAddon = new FitAddon();
    term.loadAddon(fitAddon);
    term.open(terminalRef.current);
    fitAddon.fit();

    termInstance.current = term;
    fitAddonRef.current = fitAddon;

    // Initial message
    term.write("Connecting to VM console...\r\n");

    // Connect to WebSocket
    connect(term);

    // Handle window resize
    const handleResize = () => {
      fitAddon.fit();
    };
    window.addEventListener("resize", handleResize);

    return () => {
      window.removeEventListener("resize", handleResize);
      disconnect();
      term.dispose();
      termInstance.current = null;
      fitAddonRef.current = null;
    };
  }, [vmId, connect, disconnect]);

  // Refit on container size changes
  useEffect(() => {
    const observer = new ResizeObserver(() => {
      fitAddonRef.current?.fit();
    });

    if (terminalRef.current) {
      observer.observe(terminalRef.current);
    }

    return () => {
      observer.disconnect();
    };
  }, []);

  return (
    <div className={`relative ${className || ""}`}>
      {/* Connection status indicator */}
      <div className="absolute top-2 right-2 z-10 flex items-center gap-2">
        <div
          className={`h-2 w-2 rounded-full ${
            isConnected
              ? "bg-green-500"
              : isConnecting
                ? "bg-yellow-500 animate-pulse"
                : "bg-red-500"
          }`}
        />
        <span className="text-xs text-gray-400">
          {isConnected
            ? "Connected"
            : isConnecting
              ? "Connecting..."
              : "Disconnected"}
        </span>
      </div>

      {/* Terminal container */}
      <div
        ref={terminalRef}
        className="h-full w-full"
        style={{ minHeight: "400px" }}
      />
    </div>
  );
}
