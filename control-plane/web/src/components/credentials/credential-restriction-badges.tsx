import { Badge } from "@/components/ui/badge";
import type { CredentialRestriction } from "@/types/api";

/** Whether a restriction narrows anything at all. */
export function isUnrestricted(restriction?: CredentialRestriction): boolean {
  if (!restriction) return true;
  if (restriction.nodeType || restriction.nodeId) return false;
  const actions = restriction.actions ?? ["*"];
  return actions.length === 1 && actions[0] === "*";
}

/**
 * Long action lists are real — a legacy read-scoped credential resolves to
 * every `:read` and `:list` in the registry — and thirty badges in a table cell
 * is not information, it's noise.
 */
const MAX_VISIBLE_ACTIONS = 6;

interface CredentialRestrictionBadgesProps {
  restriction?: CredentialRestriction;
  /** Shown when the credential narrows nothing. */
  unrestrictedLabel?: string;
}

/**
 * A credential's restriction as badges: its action patterns, plus its node
 * scope when it has one.
 *
 * "Full access" is stated rather than left blank — an empty cell reads as
 * "unknown", and the whole point of showing this is that the reader can tell a
 * scoped token from an unscoped one at a glance.
 */
export function CredentialRestrictionBadges({
  restriction,
  unrestrictedLabel = "Full access",
}: CredentialRestrictionBadgesProps) {
  if (isUnrestricted(restriction)) {
    return (
      <Badge variant="secondary" className="bg-muted text-foreground">
        {unrestrictedLabel}
      </Badge>
    );
  }

  const actions = restriction?.actions ?? [];
  const unrestrictedActions = actions.length === 1 && actions[0] === "*";

  return (
    <div className="flex flex-wrap gap-1">
      {unrestrictedActions ? (
        <Badge variant="secondary" className="bg-muted text-foreground">
          All actions
        </Badge>
      ) : (
        <>
          {actions.slice(0, MAX_VISIBLE_ACTIONS).map((action) => (
            <Badge
              key={action}
              variant="secondary"
              className={
                action === "read"
                  ? "bg-muted text-foreground"
                  : "bg-muted text-foreground font-mono text-xs"
              }
            >
              {action === "read" ? "Read only" : action}
            </Badge>
          ))}
          {actions.length > MAX_VISIBLE_ACTIONS && (
            <Badge
              variant="outline"
              className="border-input text-muted-foreground text-xs"
              title={actions.join(", ")}
            >
              +{actions.length - MAX_VISIBLE_ACTIONS} more
            </Badge>
          )}
        </>
      )}
      {restriction?.nodeType && restriction?.nodeId && (
        <Badge
          variant="outline"
          className="border-input text-foreground font-mono text-xs"
          title={`${restriction.nodeType} ${restriction.nodeId}`}
        >
          in {restriction.nodeType.replace(/_/g, " ")} {restriction.nodeId.slice(0, 8)}
        </Badge>
      )}
    </div>
  );
}
