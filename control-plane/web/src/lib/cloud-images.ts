import type { CPUArchitecture } from "@/types/api";

/**
 * Curated cloud images from well-known upstream sources, so the common case —
 * "give me a current Ubuntu" — doesn't require hunting down a URL.
 *
 * Every URL here was verified to serve a real image: a 200 whose first bytes
 * are the format's magic, not just a 200. Ubuntu, Debian and Rocky publish a
 * real `current`/`latest` path, so those track point releases on their own.
 * Fedora, Alpine and openSUSE are pinned to an exact build and need bumping
 * when a new one lands.
 *
 * A pinned URL going stale 404s, which fails the image loudly with an error
 * message. That is the *good* failure mode here, and worth preferring over a
 * convenience alias that might quietly resolve to something that isn't a disk
 * image — see the openSUSE entry for a symlink that does exactly that.
 *
 * FreeBSD is deliberately absent: it ships only `.xz`-compressed VM images and
 * the control plane has no decompression, so a download would land as an
 * unbootable archive. Adding it means teaching ImageFetchService to decompress.
 */
export interface CloudImageVersion {
  /** Display label, e.g. "24.04 LTS" or "12 · Bookworm". */
  label: string;
  /** Download URL per architecture; an architecture is offered only if present. */
  urls: Partial<Record<CPUArchitecture, string>>;
  /** Approximate x86_64 download size, for the size badge. Measured from the
   *  mirror at authoring time; arm64 differs slightly and point releases drift,
   *  so treat it as a hint about magnitude rather than a promise. */
  size: string;
}

export interface CloudImageDistro {
  id: string;
  name: string;
  /** Single character for the logo tile. */
  logo: string;
  /** Brand colour for the logo tile. Literal brand values, not theme tokens. */
  color: string;
  description: string;
  /** Newest first — the first entry is the default selection. */
  versions: CloudImageVersion[];
}

export const CLOUD_IMAGE_DISTROS: CloudImageDistro[] = [
  {
    id: "ubuntu",
    name: "Ubuntu Server",
    logo: "U",
    color: "#E95420",
    description: "Most widely-deployed cloud OS",
    versions: [
      {
        label: "26.04 LTS",
        size: "819 MB",
        urls: {
          x86_64:
            "https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64.img",
          arm64:
            "https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-arm64.img",
        },
      },
      {
        label: "24.04 LTS",
        size: "592 MB",
        urls: {
          x86_64:
            "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img",
          arm64:
            "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.img",
        },
      },
      {
        label: "22.04 LTS",
        size: "698 MB",
        urls: {
          x86_64:
            "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img",
          arm64:
            "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-arm64.img",
        },
      },
    ],
  },
  {
    id: "debian",
    name: "Debian",
    logo: "D",
    color: "#A81D33",
    description: "Rock-solid, minimal stable base",
    versions: [
      {
        label: "13 · Trixie",
        size: "324 MB",
        urls: {
          x86_64:
            "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2",
          arm64:
            "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-arm64.qcow2",
        },
      },
      {
        label: "12 · Bookworm",
        size: "330 MB",
        urls: {
          x86_64:
            "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2",
          arm64:
            "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-arm64.qcow2",
        },
      },
    ],
  },
  {
    id: "fedora",
    name: "Fedora Cloud",
    logo: "F",
    color: "#3C6EB4",
    description: "Latest upstream packages",
    versions: [
      {
        label: "44",
        size: "556 MB",
        urls: {
          x86_64:
            "https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2",
          arm64:
            "https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/aarch64/images/Fedora-Cloud-Base-Generic-44-1.7.aarch64.qcow2",
        },
      },
      {
        label: "43",
        size: "556 MB",
        urls: {
          x86_64:
            "https://download.fedoraproject.org/pub/fedora/linux/releases/43/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-43-1.6.x86_64.qcow2",
          arm64:
            "https://download.fedoraproject.org/pub/fedora/linux/releases/43/Cloud/aarch64/images/Fedora-Cloud-Base-Generic-43-1.6.aarch64.qcow2",
        },
      },
    ],
  },
  {
    id: "rocky",
    name: "Rocky Linux",
    logo: "R",
    color: "#10B981",
    description: "RHEL-compatible enterprise",
    versions: [
      {
        label: "10",
        size: "519 MB",
        urls: {
          x86_64:
            "https://download.rockylinux.org/pub/rocky/10/images/x86_64/Rocky-10-GenericCloud-Base.latest.x86_64.qcow2",
          arm64:
            "https://download.rockylinux.org/pub/rocky/10/images/aarch64/Rocky-10-GenericCloud-Base.latest.aarch64.qcow2",
        },
      },
      {
        label: "9",
        size: "616 MB",
        urls: {
          x86_64:
            "https://download.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2",
          arm64:
            "https://download.rockylinux.org/pub/rocky/9/images/aarch64/Rocky-9-GenericCloud-Base.latest.aarch64.qcow2",
        },
      },
    ],
  },
  {
    id: "alpine",
    name: "Alpine Linux",
    logo: "A",
    color: "#0D597F",
    description: "Tiny, security-focused musl base",
    versions: [
      {
        label: "3.24",
        size: "175 MB",
        urls: {
          x86_64:
            "https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/cloud/generic_alpine-3.24.1-x86_64-bios-cloudinit-r0.qcow2",
          arm64:
            "https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/cloud/generic_alpine-3.24.1-aarch64-uefi-cloudinit-r0.qcow2",
        },
      },
      {
        label: "3.23",
        size: "183 MB",
        urls: {
          x86_64:
            "https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/cloud/generic_alpine-3.23.5-x86_64-bios-cloudinit-r0.qcow2",
          arm64:
            "https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/cloud/generic_alpine-3.23.5-aarch64-uefi-cloudinit-r0.qcow2",
        },
      },
    ],
  },
  {
    id: "opensuse",
    name: "openSUSE Leap",
    logo: "S",
    color: "#73BA25",
    description: "Community enterprise distro",
    // Pinned to the versioned build rather than the shorter
    // `openSUSE-Leap-15.6.x86_64-NoCloud.qcow2` name, which is a *symlink* to
    // it. Whether that alias works depends on the mirror the redirector happens
    // to pick: mirrors that follow symlinks serve the real image, while
    // rsync.opensuse.org 404s it and a mirror that materialised the link would
    // serve its ~57-byte target path as a 200 — which downloadFile would store
    // as a perfectly "ready" image. These names go stale when a new build lands
    // (like Fedora and Alpine below), but a stale URL 404s loudly instead.
    versions: [
      // Leap 16.0 is intentionally not offered: its Cloud:Images repo publishes
      // only Azure builds and metadata — no NoCloud qcow2 exists to point at.
      {
        label: "15.6",
        size: "689 MB",
        urls: {
          x86_64:
            "https://download.opensuse.org/repositories/Cloud:/Images:/Leap_15.6/images/openSUSE-Leap-15.6.x86_64-1.0.2-NoCloud-Build2.109.qcow2",
          arm64:
            "https://download.opensuse.org/repositories/Cloud:/Images:/Leap_15.6/images/openSUSE-Leap-15.6.aarch64-1.0.2-NoCloud-Build2.109.qcow2",
        },
      },
      {
        label: "15.5",
        size: "643 MB",
        urls: {
          x86_64:
            "https://download.opensuse.org/repositories/Cloud:/Images:/Leap_15.5/images/openSUSE-Leap-15.5.x86_64-1.0.1-NoCloud-Build6.180.qcow2",
          arm64:
            "https://download.opensuse.org/repositories/Cloud:/Images:/Leap_15.5/images/openSUSE-Leap-15.5.aarch64-1.0.1-NoCloud-Build6.180.qcow2",
        },
      },
    ],
  },
];

/** Suggested image name for a catalog selection, e.g. `ubuntu-24-04-lts`. */
export function catalogImageName(
  distro: CloudImageDistro,
  version: CloudImageVersion,
): string {
  const versionSlug = version.label
    .toLowerCase()
    .replace(/·/g, " ")
    .trim()
    .replace(/[\s.]+/g, "-")
    .replace(/-+/g, "-");
  return `${distro.id}-${versionSlug}`;
}
