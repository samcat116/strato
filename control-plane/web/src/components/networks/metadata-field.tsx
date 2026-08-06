"use client";

/**
 * Toggle for the network's instance metadata service (STR-49).
 *
 * Shared by the create and edit dialogs, and deliberately not folded into
 * {@link DHCPFields}: the metadata service is realized as an OVN localport on
 * the network's switch, not as a DHCP option, and it stays available on a
 * network with DHCP turned off.
 */
export function MetadataField({
  value,
  onChange,
  disabled,
}: {
  value: boolean;
  onChange: (value: boolean) => void;
  disabled?: boolean;
}) {
  return (
    <div className="space-y-2 rounded-md border border-border p-3">
      <label className="flex items-center gap-2 text-sm text-foreground">
        <input
          type="checkbox"
          checked={value}
          onChange={(e) => onChange(e.target.checked)}
          disabled={disabled}
          className="h-4 w-4 rounded border-input bg-background accent-blue-600"
        />
        Publish the instance metadata service
      </label>
      <p className="text-xs text-muted-foreground">
        Guests can reach their own metadata at 169.254.169.254 (and
        fd00:ec2::254 on dual-stack networks), the addresses cloud-init already
        looks for. Turning this off removes the address from the network.
      </p>
    </div>
  );
}
