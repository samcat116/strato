import { useRef, useCallback, useState, useEffect } from "react";
import { vmsApi } from "@/lib/api/vms";

// VM graphics console hook (backend issue #566), modeled on use-sandbox-exec.ts.
//
// Two steps, like exec: POST mints a single-use session, then the returned
// same-origin `websocketPath` is attached. The socket is then handed to noVNC,
// which owns every frame from that point on:
//   server -> browser: {"type":"ready"} once the agent has attached to the VM's
//                      VNC socket; {"type":"error","message":"..."} if it could
//                      not. After `ready`, every frame is binary RFB.
//   browser -> server: binary RFB client messages, all written by noVNC.
//
// The `ready` gate is why the live WebSocket is passed to RFB rather than a
// URL: noVNC would otherwise send the RFB handshake the instant the socket
// opened, before the agent's end of the relay existed, and those bytes would
// be dropped — leaving the handshake stalled with no error anywhere.
//
// One-shot, like exec: a closed session is not auto-reconnected. The caller
// starts a fresh one, which mints a new server-side session.

// Type-only, so it does not pull noVNC into the module graph at import time;
// the value is loaded with a dynamic import below. Declarations for the
// package live in src/types/novnc.d.ts.
import type RFBType from "@novnc/novnc";

interface UseVNCOptions {
  vmId: string;
  onConnected?: () => void;
  onDisconnected?: (reason?: string) => void;
  onError?: (error: Error) => void;
}

interface UseVNCReturn {
  /** Mint a session, attach the socket, and render into `container`. */
  connect: (container: HTMLElement) => Promise<void>;
  disconnect: () => void;
  /** Send Ctrl+Alt+Del to the guest (the key combination a browser swallows). */
  sendCtrlAltDel: () => void;
  isConnected: boolean;
  isConnecting: boolean;
  error: Error | null;
}

type ServerControlFrame = { type: "ready" } | { type: "error"; message: string };

export function useVNC({
  vmId,
  onConnected,
  onDisconnected,
  onError,
}: UseVNCOptions): UseVNCReturn {
  const wsRef = useRef<WebSocket | null>(null);
  const rfbRef = useRef<RFBType | null>(null);
  // Bumped by every teardown (reconnect, unmount) so a connect() suspended in
  // the mint POST or the noVNC import can detect it went stale and must not
  // open a socket against a container that is gone.
  const sessionEpochRef = useRef(0);
  const [isConnected, setIsConnected] = useState(false);
  const [isConnecting, setIsConnecting] = useState(false);
  const [error, setError] = useState<Error | null>(null);

  // Hold the latest callbacks in refs so `connect` stays memoized on [vmId]
  // alone. The VM detail page polls every 5s, and without this each poll's
  // re-render would tear down a live console (same pattern as use-console.ts).
  const onConnectedRef = useRef(onConnected);
  const onDisconnectedRef = useRef(onDisconnected);
  const onErrorRef = useRef(onError);
  useEffect(() => {
    onConnectedRef.current = onConnected;
    onDisconnectedRef.current = onDisconnected;
    onErrorRef.current = onError;
  }, [onConnected, onDisconnected, onError]);

  const teardownSocket = useCallback(() => {
    sessionEpochRef.current += 1;
    // Disconnect RFB first so it stops writing into a socket we are closing.
    rfbRef.current?.disconnect();
    rfbRef.current = null;

    const ws = wsRef.current;
    if (ws) {
      ws.onopen = null;
      ws.onmessage = null;
      ws.onclose = null;
      ws.onerror = null;
      ws.close();
      wsRef.current = null;
    }
  }, []);

  const connect = useCallback(
    async (container: HTMLElement) => {
      teardownSocket();
      const epoch = sessionEpochRef.current;

      setIsConnecting(true);
      setIsConnected(false);
      setError(null);

      const fail = (e: unknown) => {
        const err = e instanceof Error ? e : new Error(String(e));
        setError(err);
        setIsConnecting(false);
        onErrorRef.current?.(err);
      };

      let websocketPath: string;
      try {
        // The server's reason is the useful part here: 409 means the VM was
        // created headless, 503 means its agent cannot serve a display right
        // now. Both are actionable, and neither is a generic failure.
        websocketPath = (await vmsApi.startVNCSession(vmId)).websocketPath;
      } catch (e) {
        fail(e);
        return;
      }

      // noVNC touches `document` while its module is evaluated, so it can only
      // be imported in the browser, at use time.
      let RFB: typeof RFBType;
      try {
        RFB = (await import("@novnc/novnc")).default;
      } catch (e) {
        fail(e);
        return;
      }

      // The component may have unmounted (or reconnected) while the POST or the
      // import was in flight. The unclaimed session just expires server-side.
      if (sessionEpochRef.current !== epoch) return;

      const protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
      const ws = new WebSocket(`${protocol}//${window.location.host}${websocketPath}`);
      ws.binaryType = "arraybuffer";
      wsRef.current = ws;

      ws.onmessage = (event) => {
        // Only pre-`ready` control frames are ours; once RFB is attached it
        // takes over `onmessage` and every later frame is its own.
        if (typeof event.data !== "string") return;

        let frame: ServerControlFrame;
        try {
          frame = JSON.parse(event.data);
        } catch {
          return; // Ignore unparseable text frames.
        }

        if (frame.type === "error") {
          fail(new Error(frame.message));
          teardownSocket();
          return;
        }
        if (frame.type !== "ready") return;
        if (sessionEpochRef.current !== epoch) return;

        // The agent is attached to the VM's VNC socket, so the RFB handshake
        // now has somewhere to land. Handing RFB the live socket also transfers
        // ownership of `onmessage`.
        const rfb = new RFB(container, ws, { shared: true });
        rfb.scaleViewport = true;
        rfb.clipViewport = false;
        rfb.focusOnClick = true;
        rfbRef.current = rfb;

        rfb.addEventListener("connect", () => {
          setIsConnecting(false);
          setIsConnected(true);
          onConnectedRef.current?.();
        });
        rfb.addEventListener("disconnect", () => {
          setIsConnected(false);
          setIsConnecting(false);
          onDisconnectedRef.current?.();
        });
        // There is no VNC password: the Unix socket plus the control plane's
        // authorization is the security boundary. A guest whose QEMU somehow
        // asks for credentials is a misconfiguration, so say so rather than
        // silently offering an empty password.
        rfb.addEventListener("credentialsrequired", () => {
          fail(new Error("This VM's VNC server unexpectedly requires a password"));
          teardownSocket();
        });
      };

      ws.onclose = (event) => {
        setIsConnected(false);
        setIsConnecting(false);
        onDisconnectedRef.current?.(event.reason || undefined);
      };

      ws.onerror = () => {
        // Only meaningful before RFB attaches; afterwards noVNC reports through
        // its own `disconnect` event.
        if (!rfbRef.current) fail(new Error("WebSocket connection failed"));
      };
    },
    [vmId, teardownSocket]
  );

  const disconnect = useCallback(() => {
    teardownSocket();
    setIsConnected(false);
    setIsConnecting(false);
  }, [teardownSocket]);

  const sendCtrlAltDel = useCallback(() => {
    rfbRef.current?.sendCtrlAltDel();
  }, []);

  // Full teardown on unmount, so a socket closed here cannot fire events into
  // an unmounted component and an in-flight connect() goes stale via the epoch.
  useEffect(() => teardownSocket, [teardownSocket]);

  return { connect, disconnect, sendCtrlAltDel, isConnected, isConnecting, error };
}
