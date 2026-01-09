"use client";

import { useEffect, useRef } from "react";
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import "@xterm/xterm/css/xterm.css";

interface ConsoleTerminalProps {
  className?: string;
}

export function ConsoleTerminal({ className }: ConsoleTerminalProps) {
  const terminalRef = useRef<HTMLDivElement>(null);
  const termInstance = useRef<Terminal | null>(null);

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

    term.write("Strato Console Ready\r\n$ ");

    termInstance.current = term;

    // Expose for external logging
    if (typeof window !== "undefined") {
      (window as Window & { logToConsole?: (message: string) => void }).logToConsole = (
        message: string
      ) => {
        term.write(`\r\n${message}\r\n$ `);
      };
    }

    // Handle window resize
    const handleResize = () => {
      fitAddon.fit();
    };
    window.addEventListener("resize", handleResize);

    return () => {
      window.removeEventListener("resize", handleResize);
      term.dispose();
      termInstance.current = null;
    };
  }, []);

  return (
    <div
      ref={terminalRef}
      className={className}
      style={{ height: "100%", width: "100%" }}
    />
  );
}
