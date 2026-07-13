import { useRef, useCallback, useState, useEffect } from "react";
import type { Terminal } from "@xterm/xterm";
import { sandboxesApi } from "@/lib/api/sandboxes";

// Sandbox exec session hook (backend issue #423), modeled on use-console.ts.
// Unlike the VM console, a session is created with an explicit POST (which
// carries the command and the fitted terminal size), then the returned
// same-origin `websocketPath` is attached. Frames:
//   browser -> server: binary = raw stdin bytes;
//                      text  = {"type":"resize","cols":C,"rows":R}
//   server -> browser: binary = terminal output bytes;
//                      text  = {"type":"ready"} | {"type":"exit","exitCode":N}
//                              | {"type":"error","message":"..."}
// Sessions are one-shot: after `exit` we mark disconnected and never
// auto-reconnect — the caller starts a fresh session (new POST) to run again.

interface UseSandboxExecOptions {
  sandboxId: string;
  onConnected?: () => void;
  onDisconnected?: (reason?: string) => void;
  onExit?: (exitCode: number) => void;
  onError?: (error: Error) => void;
}

interface UseSandboxExecReturn {
  /** POST a new exec session for `command` and attach the WebSocket. */
  start: (terminal: Terminal, command: string[]) => Promise<void>;
  disconnect: () => void;
  isConnected: boolean;
  isConnecting: boolean;
  /** Exit code of the last session that ended with an `exit` frame. */
  exitCode: number | null;
  error: Error | null;
}

type ServerControlFrame =
  | { type: "ready" }
  | { type: "exit"; exitCode: number }
  | { type: "error"; message: string };

type WSWithCleanup = WebSocket & {
  _termDisposables?: { dispose: () => void }[];
};

export function useSandboxExec({
  sandboxId,
  onConnected,
  onDisconnected,
  onExit,
  onError,
}: UseSandboxExecOptions): UseSandboxExecReturn {
  const wsRef = useRef<WSWithCleanup | null>(null);
  const isReadyRef = useRef(false);
  const hasExitedRef = useRef(false);
  const [isConnected, setIsConnected] = useState(false);
  const [isConnecting, setIsConnecting] = useState(false);
  const [exitCode, setExitCode] = useState<number | null>(null);
  const [error, setError] = useState<Error | null>(null);

  // Hold the latest callbacks in refs so `start` stays memoized on
  // [sandboxId] alone (see the identical pattern in use-console.ts —
  // otherwise parent re-renders would tear down the session).
  const onConnectedRef = useRef(onConnected);
  const onDisconnectedRef = useRef(onDisconnected);
  const onExitRef = useRef(onExit);
  const onErrorRef = useRef(onError);
  useEffect(() => {
    onConnectedRef.current = onConnected;
    onDisconnectedRef.current = onDisconnected;
    onExitRef.current = onExit;
    onErrorRef.current = onError;
  }, [onConnected, onDisconnected, onExit, onError]);

  const teardownSocket = useCallback(() => {
    const ws = wsRef.current;
    if (ws) {
      ws._termDisposables?.forEach((d) => d.dispose());
      // Detach handlers so a stale close/error event can't write into a
      // terminal that has been reset for a new session.
      ws.onopen = null;
      ws.onmessage = null;
      ws.onclose = null;
      ws.onerror = null;
      isReadyRef.current = false;
      ws.close();
      wsRef.current = null;
    }
  }, []);

  const start = useCallback(
    async (terminal: Terminal, command: string[]) => {
      // Replace any previous session (one live session per hook instance).
      teardownSocket();

      isReadyRef.current = false;
      hasExitedRef.current = false;
      setIsConnecting(true);
      setIsConnected(false);
      setExitCode(null);
      setError(null);

      let websocketPath: string;
      try {
        const session = await sandboxesApi.exec(sandboxId, {
          command,
          tty: true,
          rows: terminal.rows,
          cols: terminal.cols,
        });
        websocketPath = session.websocketPath;
      } catch (e) {
        const err = e instanceof Error ? e : new Error(String(e));
        setError(err);
        setIsConnecting(false);
        terminal.write(`\r\n\x1b[31mFailed to start session: ${err.message}\x1b[0m\r\n`);
        onErrorRef.current?.(err);
        return;
      }

      const protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
      const ws = new WebSocket(
        `${protocol}//${window.location.host}${websocketPath}`
      ) as WSWithCleanup;
      ws.binaryType = "arraybuffer";

      ws.onopen = () => {
        // Wait for the server's {"type":"ready"} before accepting input.
        terminal.write("\r\n\x1b[33mStarting process...\x1b[0m");
      };

      ws.onmessage = (event) => {
        if (event.data instanceof ArrayBuffer) {
          terminal.write(new Uint8Array(event.data));
          return;
        }
        if (typeof event.data !== "string") return;

        let frame: ServerControlFrame;
        try {
          frame = JSON.parse(event.data);
        } catch {
          return; // Ignore unparseable text frames.
        }

        switch (frame.type) {
          case "ready":
            isReadyRef.current = true;
            setIsConnecting(false);
            setIsConnected(true);
            terminal.write("\r\n\x1b[2K\r"); // Clear the "Starting process..." line
            onConnectedRef.current?.();
            break;
          case "exit":
            hasExitedRef.current = true;
            isReadyRef.current = false;
            setExitCode(frame.exitCode);
            setIsConnected(false);
            setIsConnecting(false);
            terminal.write(
              `\r\n[process exited with code ${frame.exitCode}]\r\n`
            );
            onExitRef.current?.(frame.exitCode);
            break;
          case "error": {
            const err = new Error(frame.message);
            setError(err);
            terminal.write(`\r\n\x1b[31m${frame.message}\x1b[0m\r\n`);
            onErrorRef.current?.(err);
            break;
          }
        }
      };

      ws.onclose = (event) => {
        isReadyRef.current = false;
        setIsConnected(false);
        setIsConnecting(false);
        if (!hasExitedRef.current) {
          terminal.write("\r\n\x1b[33mSession disconnected\x1b[0m\r\n");
        }
        onDisconnectedRef.current?.(event.reason || undefined);
      };

      ws.onerror = () => {
        const err = new Error("WebSocket connection failed");
        isReadyRef.current = false;
        setError(err);
        setIsConnecting(false);
        if (!hasExitedRef.current) {
          terminal.write("\r\n\x1b[31mConnection failed\x1b[0m\r\n");
        }
        onErrorRef.current?.(err);
      };

      wsRef.current = ws;

      // stdin: raw bytes as binary frames.
      const dataDisposable = terminal.onData((data) => {
        if (isReadyRef.current && ws.readyState === WebSocket.OPEN) {
          ws.send(new TextEncoder().encode(data));
        }
      });

      // Terminal resize (from FitAddon.fit() or manual resize): text JSON.
      const resizeDisposable = terminal.onResize(({ cols, rows }) => {
        if (isReadyRef.current && ws.readyState === WebSocket.OPEN) {
          ws.send(JSON.stringify({ type: "resize", cols, rows }));
        }
      });

      ws._termDisposables = [dataDisposable, resizeDisposable];
    },
    [sandboxId, teardownSocket]
  );

  const disconnect = useCallback(() => {
    teardownSocket();
  }, [teardownSocket]);

  // Cleanup on unmount
  useEffect(() => {
    return () => {
      const ws = wsRef.current;
      if (ws) {
        ws._termDisposables?.forEach((d) => d.dispose());
        ws.close();
        wsRef.current = null;
      }
    };
  }, []);

  return { start, disconnect, isConnected, isConnecting, exitCode, error };
}
