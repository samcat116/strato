import { useRef, useCallback, useState, useEffect } from "react";
import type { Terminal } from "@xterm/xterm";

interface UseConsoleOptions {
  vmId: string;
  onConnected?: () => void;
  onDisconnected?: (reason?: string) => void;
  onError?: (error: Error) => void;
}

interface UseConsoleReturn {
  connect: (terminal: Terminal) => void;
  disconnect: () => void;
  isConnected: boolean;
  isConnecting: boolean;
  error: Error | null;
}

export function useConsole({
  vmId,
  onConnected,
  onDisconnected,
  onError,
}: UseConsoleOptions): UseConsoleReturn {
  const wsRef = useRef<WebSocket | null>(null);
  const termRef = useRef<Terminal | null>(null);
  const isReadyRef = useRef(false); // Track if console is ready for input
  const [isConnected, setIsConnected] = useState(false);
  const [isConnecting, setIsConnecting] = useState(false);
  const [error, setError] = useState<Error | null>(null);

  const connect = useCallback(
    (terminal: Terminal) => {
      if (wsRef.current?.readyState === WebSocket.OPEN) {
        return;
      }

      termRef.current = terminal;
      isReadyRef.current = false; // Reset ready state
      setIsConnecting(true);
      setError(null);

      const protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
      const ws = new WebSocket(
        `${protocol}//${window.location.host}/api/vms/${vmId}/console`
      );

      ws.binaryType = "arraybuffer";

      ws.onopen = () => {
        // Don't mark as fully connected yet - wait for "ready" message from server
        // The server will send "ready" after the agent confirms console socket connection
        terminal.write("\r\n\x1b[33mWaiting for console...\x1b[0m");
      };

      ws.onmessage = (event) => {
        if (event.data instanceof ArrayBuffer) {
          const text = new TextDecoder().decode(event.data);
          terminal.write(text);
        } else if (typeof event.data === "string") {
          // Handle text messages
          if (event.data === "ready") {
            // Server confirms console is ready - now allow input
            isReadyRef.current = true;
            setIsConnecting(false);
            setIsConnected(true);
            terminal.write("\r\n\x1b[32mConnected to VM console\x1b[0m\r\n\r\n");
            onConnected?.();
          } else if (event.data.startsWith("error:")) {
            terminal.write(
              `\r\n\x1b[31m${event.data}\x1b[0m\r\n`
            );
          } else {
            terminal.write(event.data);
          }
        }
      };

      ws.onclose = (event) => {
        isReadyRef.current = false;
        setIsConnected(false);
        setIsConnecting(false);
        terminal.write("\r\n\x1b[33mDisconnected from VM console\x1b[0m\r\n");
        onDisconnected?.(event.reason || undefined);
      };

      ws.onerror = () => {
        const err = new Error("WebSocket connection failed");
        isReadyRef.current = false;
        setError(err);
        setIsConnecting(false);
        terminal.write(
          "\r\n\x1b[31mFailed to connect to VM console\x1b[0m\r\n"
        );
        onError?.(err);
      };

      wsRef.current = ws;

      // Set up terminal input handler
      const disposable = terminal.onData((data) => {
        // Only send input if console is ready and WebSocket is open
        if (isReadyRef.current && ws.readyState === WebSocket.OPEN) {
          // Send data as binary
          const encoder = new TextEncoder();
          ws.send(encoder.encode(data));
        }
      });

      // Store disposable for cleanup
      (ws as WebSocket & { _termDisposable?: { dispose: () => void } })._termDisposable = disposable;
    },
    [vmId, onConnected, onDisconnected, onError]
  );

  const disconnect = useCallback(() => {
    if (wsRef.current) {
      // Clean up terminal disposable
      const ws = wsRef.current as WebSocket & { _termDisposable?: { dispose: () => void } };
      ws._termDisposable?.dispose();

      isReadyRef.current = false;
      wsRef.current.close();
      wsRef.current = null;
    }
  }, []);

  // Cleanup on unmount
  useEffect(() => {
    return () => {
      if (wsRef.current) {
        const ws = wsRef.current as WebSocket & { _termDisposable?: { dispose: () => void } };
        ws._termDisposable?.dispose();
        wsRef.current.close();
      }
    };
  }, []);

  return { connect, disconnect, isConnected, isConnecting, error };
}
