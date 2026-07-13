"use client";

import { useEffect, useRef, useState, useCallback } from "react";
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { Play, RotateCcw } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { useSandboxExec } from "@/lib/hooks";
import "@xterm/xterm/css/xterm.css";

interface SandboxTerminalProps {
  sandboxId: string;
  className?: string;
  onConnected?: () => void;
  onDisconnected?: (reason?: string) => void;
}

const DEFAULT_COMMAND = "/bin/sh";

// Minimal shell-ish tokenizer: whitespace-separated, with single/double
// quotes to group arguments (no escapes or expansion — the command runs via
// exec argv, not a shell).
function parseCommand(input: string): string[] {
  const tokens: string[] = [];
  const re = /"([^"]*)"|'([^']*)'|(\S+)/g;
  let match;
  while ((match = re.exec(input)) !== null) {
    tokens.push(match[1] ?? match[2] ?? match[3]);
  }
  return tokens;
}

export function SandboxTerminal({
  sandboxId,
  className,
  onConnected,
  onDisconnected,
}: SandboxTerminalProps) {
  const terminalRef = useRef<HTMLDivElement>(null);
  const termInstance = useRef<Terminal | null>(null);
  const fitAddonRef = useRef<FitAddon | null>(null);

  const [command, setCommand] = useState(DEFAULT_COMMAND);
  // Keep the latest command in a ref so the run callback (used from the
  // mount effect) doesn't need `command` as a dependency.
  const commandRef = useRef(command);
  useEffect(() => {
    commandRef.current = command;
  }, [command]);

  const handleError = useCallback((error: Error) => {
    console.error("Sandbox exec error:", error);
  }, []);

  const { start, disconnect, isConnected, isConnecting, exitCode } =
    useSandboxExec({
      sandboxId,
      onConnected,
      onDisconnected,
      onError: handleError,
    });

  // Start a fresh exec session with the current command. Always tty=true
  // from this UI; rows/cols come from the fitted terminal at POST time.
  const runSession = useCallback(() => {
    const term = termInstance.current;
    if (!term) return;

    const argv = parseCommand(commandRef.current);
    if (argv.length === 0) return;

    term.reset();
    fitAddonRef.current?.fit();
    void start(term, argv);
  }, [start]);

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
    });

    const fitAddon = new FitAddon();
    term.loadAddon(fitAddon);
    term.open(terminalRef.current);
    fitAddon.fit();

    termInstance.current = term;
    fitAddonRef.current = fitAddon;

    // Start the default session immediately (parity with the VM console tab).
    runSession();

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
  }, [sandboxId, runSession, disconnect]);

  // Refit on container size changes (onResize in the hook relays new
  // dimensions to the server as a resize control frame).
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

  const isActive = isConnected || isConnecting;

  return (
    <div className={`flex flex-col ${className || ""}`}>
      {/* Command row */}
      <div className="flex items-center gap-2 p-2 border-b border-border bg-card">
        <Input
          value={command}
          onChange={(e) => setCommand(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter" && !isActive) {
              runSession();
            }
          }}
          placeholder={DEFAULT_COMMAND}
          spellCheck={false}
          className="flex-1 font-mono text-sm bg-muted border-input"
        />
        <Button
          variant="outline"
          size="sm"
          onClick={runSession}
          disabled={isConnecting || parseCommand(command).length === 0}
          className="border-input"
        >
          {isActive ? (
            <>
              <RotateCcw className="h-4 w-4 mr-1" />
              Restart
            </>
          ) : (
            <>
              <Play className="h-4 w-4 mr-1" />
              Run
            </>
          )}
        </Button>
      </div>

      {/* Terminal area */}
      <div className="relative flex-1">
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
          <span className="text-xs text-muted-foreground">
            {isConnected
              ? "Connected"
              : isConnecting
                ? "Connecting..."
                : exitCode != null
                  ? `Exited (${exitCode})`
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
    </div>
  );
}
