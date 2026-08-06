// Surfacing the tier-2 ceilings that narrow a role grant (STR-110).
//
// A grant is never refused over a ceiling — the evaluator subtracts the
// ceilinged actions and leaves the rest of the role working, so the write does
// too. The API reports what was subtracted, and this is where the person who
// just made the grant gets told: the alternative is discovering it as an
// unexplained denial days later.

import { toast } from "sonner";
import type { GrantCeiling, GrantWriteResponse } from "@/types/api";

/** `no-vm-stop (set by alice@acme) removes vm:stop`. */
function describe(ceiling: GrantCeiling): string {
  const name = ceiling.guardrail.split("/").pop() ?? ceiling.guardrail;
  const who = ceiling.setBy ? ` (set by ${ceiling.setBy})` : "";
  const actions = ceiling.ceilingedActions.join(", ");
  return `${name}${who} removes ${actions}`;
}

/**
 * Warn about the ceilings narrowing a grant that just succeeded. A no-op in
 * the ordinary case, where nothing narrows it.
 *
 * `subject` names what was granted, so the toast reads as a footnote to the
 * success message rather than as a second, contradictory verdict.
 */
export function warnAboutGrantCeilings(
  result: GrantWriteResponse | undefined,
  subject: string
): void {
  // An empty list means "nothing narrows this" only when the analysis ran.
  // Saying nothing when it didn't would turn a missing answer into an
  // all-clear — the one reading the server can't correct later.
  if (result?.analysisUnavailable) {
    toast.warning(`Couldn't check guardrails against ${subject}`, {
      description: `${result.analysisUnavailable}. Any guardrails narrowing this grant are still enforced, but can't be listed here.`,
      duration: 10000,
    });
    return;
  }
  const ceilings = result?.ceilings ?? [];
  if (ceilings.length === 0) return;
  toast.warning(`${subject} is narrowed by a guardrail`, {
    description: ceilings.map(describe).join("; "),
    duration: 10000,
  });
}
