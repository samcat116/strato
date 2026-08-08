// Maps known raw backend error strings to messages a user can act on.
//
// The control plane forwards internal error descriptions (AgentServiceError in
// AgentService+Types.swift) straight into the HTTP `reason` field, so failed
// VM operations otherwise surface strings like
// "VM not mapped to any agent: 4F1C...". Patterns are matched anywhere in the
// message because controllers wrap them (e.g. "Failed to start VM: ...").
const KNOWN_ERRORS: Array<{ pattern: RegExp; message: string }> = [
  {
    pattern: /VM placement failed/i,
    message:
      "The VM couldn't be placed on a hypervisor host. Check that an agent is online with enough free resources.",
  },
  {
    pattern: /Agent not found/i,
    message: "The hypervisor host for this VM is no longer registered.",
  },
  {
    pattern: /Invalid response from agent/i,
    message:
      "The hypervisor host returned an unexpected response. Please try again.",
  },
];

/**
 * Returns a user-friendly message for an error: known backend errors are
 * mapped to friendly text, other errors keep their message (which is still
 * more informative than a generic fallback), and non-Error values fall back
 * to `fallback`.
 */
export function friendlyErrorMessage(error: unknown, fallback: string): string {
  const raw =
    error instanceof Error
      ? error.message
      : typeof error === "string"
        ? error
        : "";

  for (const { pattern, message } of KNOWN_ERRORS) {
    if (pattern.test(raw)) {
      return message;
    }
  }

  return raw || fallback;
}
