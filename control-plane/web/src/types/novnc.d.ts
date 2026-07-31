// noVNC ships no TypeScript declarations (`@novnc/novnc` is plain ESM, and
// there is no `@types/` package for it). This declares the slice of its RFB
// API the graphics console uses (issue #566), rather than letting the import
// fall back to `any`.
//
// See node_modules/@novnc/novnc/docs/API.md for the full surface.
declare module "@novnc/novnc" {
  /**
   * A connection to a VNC server, rendering into `target`.
   *
   * `urlOrChannel` accepts an already-open `WebSocket` as well as a URL, which
   * is what lets the control plane's `{"type":"ready"}` handshake complete
   * before RFB takes ownership of the socket.
   */
  export default class RFB {
    constructor(
      target: HTMLElement,
      urlOrChannel: WebSocket | string,
      options?: {
        /** Allow other clients to stay connected to the same framebuffer. */
        shared?: boolean;
        credentials?: { username?: string; password?: string; target?: string };
        repeaterID?: string;
        wsProtocols?: string[];
      }
    );

    /** Scale the remote framebuffer to fit the container. */
    scaleViewport: boolean;
    /** Crop rather than scale when the framebuffer exceeds the container. */
    clipViewport: boolean;
    /** Take keyboard focus when the canvas is clicked. */
    focusOnClick: boolean;
    /** Whether keyboard input is forwarded to the guest. */
    viewOnly: boolean;

    /** Close the connection. Safe to call more than once. */
    disconnect(): void;
    /** Send the one key combination browsers intercept before the guest. */
    sendCtrlAltDel(): void;
    /** Send an arbitrary key event to the guest. */
    sendKey(keysym: number, code: string | null, down?: boolean): void;
    focus(): void;
    blur(): void;

    // `connect`, `disconnect`, `credentialsrequired`, `securityfailure`,
    // `clipboard`, `bell`, `desktopname`.
    addEventListener(type: string, listener: (event: CustomEvent) => void): void;
    removeEventListener(type: string, listener: (event: CustomEvent) => void): void;
  }
}
