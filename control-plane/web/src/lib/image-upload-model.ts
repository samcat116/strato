import type { CPUArchitecture, ImageFormat } from "@/types/api";

export const IMAGE_ARCHITECTURES: CPUArchitecture[] = ["x86_64", "arm64"];
export const IMAGE_DISK_FORMATS: ImageFormat[] = [
  "qcow2",
  "raw",
  "vmdk",
  "vhd",
  "vhdx",
];
export type ImageFormatChoice = ImageFormat | "auto";
export const IMAGE_UPLOAD_ACCENT = "#3c87dd";
export const IMAGE_UPLOAD_FIELD_CLASS =
  "h-[38px] w-full rounded-[9px] border border-input bg-card px-3 font-mono text-[13px] font-medium text-foreground outline-none transition focus:border-[#3c87dd] focus:shadow-[0_0_0_3px_rgba(60,135,221,0.14)]";
export const IMAGE_UPLOAD_LABEL_CLASS =
  "mb-1.5 block text-xs font-semibold text-muted-foreground";

/** Extensions that do not identify a format deliberately return auto. */
export function imageFormatFromURL(url: string): ImageFormatChoice {
  const match = url.match(/\.(qcow2|raw|vmdk|vhdx?)(\?|$)/i);
  return match ? (match[1].toLowerCase() as ImageFormat) : "auto";
}

export function isValidImageChecksum(value: string): boolean {
  return /^[a-f0-9]{64}$/i.test(value.trim());
}
