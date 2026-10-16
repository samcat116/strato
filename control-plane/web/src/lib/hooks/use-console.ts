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

type ConsoleSocket = WebSocket & {
  _termDisposable?: { dispose: () => void };
};

export function useConsole({
  vmId,
  onConnected,
  onDisconnected,
  onError,
}: UseConsoleOptions): UseConsoleReturn {
  const wsRef = useRef<ConsoleSocket | null>(null);
  const isReadyRef = useRef(false); // Track if console is ready for input
  const [isConnected, setIsConnected] = useState(false);
  const [isConnecting, setIsConnecting] = useState(false);
  const [error, setError] = useState<Error | null>(null);

  // Hold the latest callbacks in refs so `connect` can stay memoized on [vmId]
  // alone. Otherwise a parent re-render (e.g. VM status polling) passes fresh
  // inline callbacks, changing `connect`'s identity, which re-runs the terminal
  // mount effect and tears down + reopens the WebSocket on every poll.
  const onConnectedRef = useRef(onConnected);
  const onDisconnectedRef = useRef(onDisconnected);
  const onErrorRef = useRef(onError);
  useEffect(() => {
    onConnectedRef.current = onConnected;
    onDisconnectedRef.current = onDisconnected;
    onErrorRef.current = onError;
  }, [onConnected, onDisconnected, onError]);

  const teardownSocket = useCallback(() => {
    const ws = wsRef.current;
    wsRef.current = null;
    isReadyRef.current = false;
    if (!ws) return;
    ws._termDisposable?.dispose();
    ws.onopen = null;
    ws.onmessage = null;
    ws.onclose = null;
    ws.onerror = null;
    ws.close();
  }, []);

  const connect = useCallback(
    (terminal: Terminal) => {
      if (wsRef.current && (wsRef.current.readyState === WebSocket.OPEN ||
          wsRef.current.readyState === WebSocket.CONNECTING)) {
        return;
      }

      teardownSocket();
      setIsConnecting(true);
      setIsConnected(false);
      setError(null);

      const protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
      const ws = new WebSocket(
        `${protocol}//${window.location.host}/api/vms/${vmId}/console`
      ) as ConsoleSocket;

      ws.binaryType = "arraybuffer";

      ws.onopen = () => {
        if (wsRef.current !== ws) return;
        // Don't mark as fully connected yet - wait for "ready" message from server
        // The server will send "ready" after the agent confirms console socket connection
        terminal.write("\r\n\x1b[33mWaiting for console...\x1b[0m");
      };

      ws.onmessage = (event) => {
        if (wsRef.current !== ws) return;
        if (event.data instanceof ArrayBuffer) {
          // xterm retains UTF-8 decoder state across binary frames.
          terminal.write(new Uint8Array(event.data));
        } else if (typeof event.data === "string") {
          // Handle text messages
          if (event.data === "ready") {
            // Server confirms console is ready - now allow input
            isReadyRef.current = true;
            setIsConnecting(false);
            setIsConnected(true);
            terminal.write("\r\n\x1b[32mConnected to VM console\x1b[0m\r\n\r\n");
            onConnectedRef.current?.();
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
        if (wsRef.current !== ws) return;
        teardownSocket();
        setIsConnected(false);
        setIsConnecting(false);
        terminal.write("\r\n\x1b[33mDisconnected from VM console\x1b[0m\r\n");
        onDisconnectedRef.current?.(event.reason || undefined);
      };

      ws.onerror = () => {
        if (wsRef.current !== ws) return;
        const err = new Error("WebSocket connection failed");
        teardownSocket();
        setError(err);
        setIsConnected(false);
        setIsConnecting(false);
        terminal.write(
          "\r\n\x1b[31mFailed to connect to VM console\x1b[0m\r\n"
        );
        onErrorRef.current?.(err);
      };

      wsRef.current = ws;

      // Set up terminal input handler
      const disposable = terminal.onData((data) => {
        // Only send input if console is ready and WebSocket is open
        if (wsRef.current === ws && isReadyRef.current && ws.readyState === WebSocket.OPEN) {
          // Send data as binary
          const encoder = new TextEncoder();
          ws.send(encoder.encode(data));
        }
      });

      // Store disposable for cleanup
      ws._termDisposable = disposable;
    },
    [vmId, teardownSocket]
  );

  const disconnect = useCallback(() => {
    teardownSocket();
    setIsConnected(false);
    setIsConnecting(false);
  }, [teardownSocket]);

  // Cleanup on unmount
  useEffect(() => teardownSocket, [vmId, teardownSocket]);

  return { connect, disconnect, isConnected, isConnecting, error };
}
