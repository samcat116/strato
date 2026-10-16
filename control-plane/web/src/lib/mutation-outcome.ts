import type { ResourceConditions } from "@/types/api";

export type MutationOutcome = { done: true; error?: string } | { done: false };

/** Mirrors OperationFacade: an unobserved target shares a newer failure,
 * while a target already observed keeps its earlier successful verdict. */
export function mutationOutcome(
  conditions: ResourceConditions,
  targetGeneration: number
): MutationOutcome {
  const degraded = conditions.degraded;
  if (degraded && (
    degraded.sinceGeneration === targetGeneration ||
    (degraded.sinceGeneration > targetGeneration &&
      conditions.observedGeneration < targetGeneration)
  )) {
    return { done: true, error: degraded.reason };
  }
  if (conditions.observedGeneration >= targetGeneration &&
    (conditions.converged || conditions.targetGeneration > targetGeneration)) {
    return { done: true };
  }
  return { done: false };
}
