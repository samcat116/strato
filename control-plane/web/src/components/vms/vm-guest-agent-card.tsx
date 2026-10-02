"use client";

import { useEffect, useState } from "react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import type { VM } from "@/types/api";

export function guestAgentReachability(vm: VM, now: number): string {
  if (!vm.guestAgentEnabled) return "Not enabled";
  if (vm.status !== "Running") return "Not running";
  const observation = vm.guestAgentObservation;
  const age = observation ? now - Date.parse(observation.checkedAt) : NaN;
  if (!Number.isFinite(age) || age < -5000 || age >= 90_000) return "Unknown";
  return observation?.reachable ? "Reachable" : "Unreachable";
}

export function VMGuestAgentCard({ vm }: { vm: VM }) {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), 10_000);
    return () => clearInterval(timer);
  }, []);
  return (
    <Card>
      <CardHeader><CardTitle>Strato guest agent</CardTitle></CardHeader>
      <CardContent className="space-y-2 text-sm">
        <p>Opt-in: <strong>{vm.guestAgentEnabled ? "Enabled" : "Disabled"}</strong></p>
        <p>Reachability: <strong>{guestAgentReachability(vm, now)}</strong></p>
        {vm.guestAgentObservation && (
          <p className="text-xs text-muted-foreground">Last probe: {vm.guestAgentObservation.checkedAt}</p>
        )}
        <p className="text-xs text-muted-foreground">
          Recreation is required to change this setting. Enabled requests first-boot
          installation of an exec-capable root daemon; it does not prove installation
          succeeded. Reachability comes from a separate Strato vsock probe and expires
          after 90 seconds. Missing cloud-init, failed downloads or checksum verification
          can leave an enabled VM unreachable. This is separate from QEMU guest agent.
        </p>
      </CardContent>
    </Card>
  );
}
