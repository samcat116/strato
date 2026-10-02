"use client";

import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { useSites } from "@/lib/hooks";

export const GUARANTEED_RESOURCE_CLASS_ID = "00000000-0000-0000-0000-000000000001";

export function WorkloadResourceClassField({ siteID, onChange, disabled }: {
  siteID: string; onChange: (siteID: string) => void; disabled?: boolean;
}) {
  const { data: sites } = useSites();
  return (
    <div className="space-y-2">
      <Label htmlFor="workload-resource-class">Resource class</Label>
      <Select value={siteID || "default"} onValueChange={(value) => onChange(value === "default" ? "" : value)} disabled={disabled}>
        <SelectTrigger id="workload-resource-class"><SelectValue /></SelectTrigger>
        <SelectContent>
          <SelectItem value="default">Guaranteed · default</SelectItem>
          {(sites ?? []).map((site) => <SelectItem key={site.id} value={site.id}>Guaranteed · {site.name}</SelectItem>)}
          <SelectItem value="burstable" disabled>Burstable · unavailable</SelectItem>
        </SelectContent>
      </Select>
      <p className="text-xs text-muted-foreground">Guaranteed uses 1:1 CPU and memory accounting. Choosing a site pins placement there. Burstable requires verified runtime enforcement.</p>
    </div>
  );
}
