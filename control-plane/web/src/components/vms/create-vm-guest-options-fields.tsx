"use client";

import type { Dispatch, SetStateAction } from "react";
import { Label } from "@/components/ui/label";
import type { Image, MetadataSource } from "@/types/api";

interface VMGuestOptionsFieldsProps {
  isLoading: boolean;
  isFirecracker: boolean;
  metadataEnabled: boolean;
  setMetadataEnabled: Dispatch<SetStateAction<boolean>>;
  metadataSource: MetadataSource;
  setMetadataSource: Dispatch<SetStateAction<MetadataSource>>;
  metadataSourceForcedToISO: boolean;
  allSelectedNetworksDisableMetadata: boolean;
  selectedImage?: Image;
  secureBoot: boolean;
  setSecureBoot: Dispatch<SetStateAction<boolean>>;
  tpm: boolean;
  setTpm: Dispatch<SetStateAction<boolean>>;
  graphicsConsole: boolean;
  setGraphicsConsole: Dispatch<SetStateAction<boolean>>;
  userData: string;
  onUserDataChange: (value: string) => void;
}

export function VMGuestOptionsFields({
  isLoading,
  isFirecracker,
  metadataEnabled,
  setMetadataEnabled,
  metadataSource,
  setMetadataSource,
  metadataSourceForcedToISO,
  allSelectedNetworksDisableMetadata,
  selectedImage,
  secureBoot,
  setSecureBoot,
  tpm,
  setTpm,
  graphicsConsole,
  setGraphicsConsole,
  userData,
  onUserDataChange,
}: VMGuestOptionsFieldsProps) {
  return (
    <>
      <div className="space-y-3 rounded-md border border-border p-3">
        <div className="space-y-1">
          <Label htmlFor="metadataSource" className="text-foreground">
            Guest bootstrap source
          </Label>
          <p className="text-xs text-muted-foreground">
            {isFirecracker
              ? "Firecracker exposes guest bootstrap data through its metadata service."
              : "Choose where cloud-init reads hostname, SSH keys, and user data at first boot."}
          </p>
        </div>
        <select
          id="metadataSource"
          value={metadataSourceForcedToISO ? "iso" : metadataSource}
          onChange={(e) =>
            setMetadataSource(e.target.value as MetadataSource)
          }
          disabled={isLoading || metadataSourceForcedToISO}
          className="w-full px-3 py-2 bg-background border border-input text-foreground rounded-md focus:outline-none focus:ring-2 focus:ring-blue-500 disabled:opacity-50 disabled:cursor-not-allowed"
        >
          <option value="imds">
            Instance metadata service (x86 QEMU default)
          </option>
          <option value="iso">
            {isFirecracker ? "Firecracker MMDS" : "Seed ISO"}
          </option>
        </select>
        {isFirecracker ? (
          <p className="text-xs text-muted-foreground">
            Firecracker has no seed disk. It serves EC2-compatible
            metadata from MMDS on metadata-enabled NICs; the selected
            network must also provide DHCP so the guest can reach it.
          </p>
        ) : !metadataEnabled ? (
          <p className="text-xs text-muted-foreground">
            IMDS bootstrap requires the instance metadata service. Seed
            ISO will be used while the service is disabled.
          </p>
        ) : allSelectedNetworksDisableMetadata ? (
          <p className="text-xs text-muted-foreground">
            None of the selected networks publish instance metadata. Seed
            ISO will be used for this VM.
          </p>
        ) : selectedImage?.architecture === "arm64" &&
          metadataSource === "iso" ? (
          <p className="text-xs text-muted-foreground">
            ARM64 QEMU defaults to Seed ISO until it has an equivalent
            NoCloudNet discovery hint.
          </p>
        ) : metadataSource === "imds" ? (
          <p className="text-xs text-muted-foreground">
            The ISO keeps the network configuration needed to get online,
            then follows a <code>seedfrom</code> stub to
            169.254.169.254 for the remaining, mutable documents.
          </p>
        ) : (
          <p className="text-xs text-muted-foreground">
            The complete, immutable NoCloud payload is written to the ISO.
            Use this compatibility path when the guest cannot use IMDS.
          </p>
        )}
      </div>
      
      <div className="space-y-3 rounded-md border border-border p-3">
        <div className="space-y-1">
          <p className="text-sm font-medium text-foreground">
            Windows / Secure Boot
          </p>
          <p className="text-xs text-muted-foreground">
            Windows 11 and Server 2025 require both. Leave off for Linux
            guests.
          </p>
        </div>
        <label className="flex items-center gap-2 text-sm text-foreground">
          <input
            id="secureBoot"
            type="checkbox"
            checked={!isFirecracker && secureBoot}
            onChange={(e) => setSecureBoot(e.target.checked)}
            disabled={isLoading || isFirecracker}
            className="h-4 w-4 rounded border-input bg-background accent-blue-600"
          />
          Secure Boot
        </label>
        <label className="flex items-center gap-2 text-sm text-foreground">
          <input
            id="tpm"
            type="checkbox"
            checked={!isFirecracker && tpm}
            onChange={(e) => setTpm(e.target.checked)}
            disabled={isLoading || isFirecracker}
            className="h-4 w-4 rounded border-input bg-background accent-blue-600"
          />
          TPM 2.0
        </label>
        {isFirecracker ? (
          <p className="text-xs text-muted-foreground">
            Unavailable for this image: it boots under Firecracker, which
            has no UEFI firmware or TPM device. Use a QEMU image.
          </p>
        ) : (
          <p className="text-xs text-muted-foreground">
            Secure Boot boots signed firmware with Microsoft&apos;s keys
            enrolled. TPM 2.0 is emulated per VM and only places on nodes
            with <code>swtpm</code> installed.
          </p>
        )}
      </div>
      
      <div className="space-y-3 rounded-md border border-border p-3">
        <div className="space-y-1">
          <p className="text-sm font-medium text-foreground">Display</p>
          <p className="text-xs text-muted-foreground">
            Needed to run a graphical OS installer, or to reach a guest
            that never brings up a network.
          </p>
        </div>
        <label className="flex items-center gap-2 text-sm text-foreground">
          <input
            id="graphicsConsole"
            type="checkbox"
            checked={!isFirecracker && graphicsConsole}
            onChange={(e) => setGraphicsConsole(e.target.checked)}
            disabled={isLoading || isFirecracker}
            className="h-4 w-4 rounded border-input bg-background accent-blue-600"
          />
          Graphics console
        </label>
        {isFirecracker ? (
          <p className="text-xs text-muted-foreground">
            Unavailable for this image: it boots under Firecracker, which
            emulates no display device. Use a QEMU image.
          </p>
        ) : (
          <p className="text-xs text-muted-foreground">
            Adds a virtual display and a VNC server, shown in the VM&apos;s
            Display tab. <strong>This cannot be changed later</strong> —
            the display is fixed when the VM is created. The serial console
            works either way.
          </p>
        )}
      </div>
      
      <div className="space-y-3 rounded-md border border-border p-3">
        <div className="space-y-1">
          <p className="text-sm font-medium text-foreground">
            Instance metadata
          </p>
          <p className="text-xs text-muted-foreground">
            The link-local service at 169.254.169.254 that a guest reads
            its own configuration and identity from.
          </p>
        </div>
        <label className="flex items-center gap-2 text-sm text-foreground">
          <input
            id="metadataEnabled"
            type="checkbox"
            checked={metadataEnabled}
            onChange={(e) => {
              const enabled = e.target.checked;
              setMetadataEnabled(enabled);
              if (!enabled) setMetadataSource("iso");
            }}
            disabled={isLoading}
            className="h-4 w-4 rounded border-input bg-background accent-blue-600"
          />
          Serve instance metadata to this VM
        </label>
        <p className="text-xs text-muted-foreground">
          Turning it off denies this VM the service outright, even where
          its security groups would allow it — the lever for a workload
          you want an SSRF bug to find nothing behind.{" "}
          If the guest bootstrap source above is instance metadata,
          turning this off also prevents cloud-init from fetching its
          configuration. This switch can be changed later.
        </p>
      </div>
      
      <div className="space-y-2">
        <Label htmlFor="userData" className="text-foreground">
          Cloud-init user data{" "}
          <span className="text-muted-foreground">(optional)</span>
        </Label>
        <textarea
          id="userData"
          placeholder={"#cloud-config\npackages:\n  - nginx\nruncmd:\n  - systemctl enable --now nginx"}
          value={userData}
          onChange={(e) =>
            onUserDataChange(e.target.value)
          }
          rows={5}
          spellCheck={false}
          disabled={isLoading}
          className="w-full px-3 py-2 bg-background border border-border text-foreground rounded-md font-mono text-xs focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent disabled:opacity-50 disabled:cursor-not-allowed resize-y"
        />
        <p className="text-xs text-muted-foreground">
          {isFirecracker ? (
            <>
              Delivered through Firecracker MMDS. The uploaded rootfs
              must include cloud-init with its EC2 datasource enabled,
              and the kernel command line must not disable cloud-init.
            </>
          ) : (
            <>Runs in the guest at first boot. </>
          )}{" "}
          Accepts any cloud-init format: <code>#cloud-config</code>, a{" "}
          <code>#!</code> shell script, <code>#include</code>, a Jinja
          template, or a full MIME multipart document.
        </p>
      </div>
    </>
  );
}
