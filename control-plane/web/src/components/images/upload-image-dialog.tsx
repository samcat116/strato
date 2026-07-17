"use client";

import { useState, useRef } from "react";
import {
  ArrowDownToLine,
  Info,
  Link as LinkIcon,
  Star,
  Upload,
  X,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogClose,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { useCreateImageFromURL, useUploadImage } from "@/lib/hooks/use-images";
import {
  CLOUD_IMAGE_DISTROS,
  catalogImageName,
  type CloudImageDistro,
  type CloudImageVersion,
} from "@/lib/cloud-images";
import { cn } from "@/lib/utils";
import type { CPUArchitecture, ImageFormat } from "@/types/api";

const ARCHITECTURES: CPUArchitecture[] = ["x86_64", "arm64"];
const DISK_FORMATS: ImageFormat[] = ["qcow2", "raw", "vmdk", "vhd", "vhdx"];

/**
 * What the Disk format control can hold. "auto" means "say nothing and let the
 * server read the file", which is the only honest default: the extension often
 * doesn't name a format (`.img`, `.iso`, none at all), and defaulting to a
 * concrete value would post a claim the user never made — the server trusts an
 * explicit format whenever its own header probe finds no signature, so a raw
 * `disk.img` would be stored and displayed as qcow2.
 */
type FormatChoice = ImageFormat | "auto";

/** The blue accent from the design system. A literal, matching how the rest of
 *  the ported design references it (see organization-switcher, overview chart). */
const ACCENT = "#3c87dd";

/** Shared field styling: mono values on a bordered box, blue focus ring. */
const FIELD_CLASS =
  "h-[38px] w-full rounded-[9px] border border-input bg-card px-3 font-mono text-[13px] font-medium text-foreground outline-none transition focus:border-[#3c87dd] focus:shadow-[0_0_0_3px_rgba(60,135,221,0.14)]";

const LABEL_CLASS =
  "mb-1.5 block text-xs font-semibold text-muted-foreground";

/**
 * Best guess at a URL's disk format from its extension, for the format pill.
 *
 * Only extensions that name a format are reported. `.img`/`.iso` deliberately
 * return "auto": they say nothing about the contents — Ubuntu's cloud images
 * are `.img` but qcow2 inside — and the server settles it from the file's magic
 * bytes on download anyway. Guessing "raw" here would mislabel the most common
 * import in the catalog.
 */
function guessFormatFromURL(url: string): ImageFormat | "auto" {
  const match = url.match(/\.(qcow2|raw|vmdk|vhdx?)(\?|$)/i);
  if (!match) return "auto";
  return match[1].toLowerCase() as ImageFormat;
}

const isValidChecksum = (value: string) => /^[a-f0-9]{64}$/i.test(value.trim());

interface UploadImageDialogProps {
  projectId: string;
  onSuccess?: () => void;
}

export function UploadImageDialog({
  projectId,
  onSuccess,
}: UploadImageDialogProps) {
  const [open, setOpen] = useState(false);
  const [tab, setTab] = useState("upload");
  const [name, setName] = useState("");
  const [architecture, setArchitecture] = useState<CPUArchitecture>("x86_64");
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Upload-disk tab
  const [selectedFile, setSelectedFile] = useState<File | null>(null);
  const [format, setFormat] = useState<FormatChoice>("auto");
  const [dragging, setDragging] = useState(false);
  const [uploadProgress, setUploadProgress] = useState(0);

  // From-URL tab
  const [sourceURL, setSourceURL] = useState("");
  const [checksum, setChecksum] = useState("");

  // Popular-images tab
  const [selectedDistroId, setSelectedDistroId] = useState<string | null>(null);
  const [versionByDistro, setVersionByDistro] = useState<
    Record<string, string>
  >({});

  const fileInputRef = useRef<HTMLInputElement>(null);
  const createFromURL = useCreateImageFromURL(projectId);
  const uploadImage = useUploadImage(projectId);

  const resetForm = () => {
    setTab("upload");
    setName("");
    setArchitecture("x86_64");
    setSelectedFile(null);
    setFormat("auto");
    setDragging(false);
    setUploadProgress(0);
    setSourceURL("");
    setChecksum("");
    setSelectedDistroId(null);
    setVersionByDistro({});
    setError(null);
  };

  const handleOpenChange = (next: boolean) => {
    if (isSubmitting) return;
    if (!next) resetForm();
    setOpen(next);
  };

  const acceptFile = (file: File | undefined) => {
    if (!file) return;
    setSelectedFile(file);
    if (!name) {
      setName(file.name.replace(/\.[^.]+$/, ""));
    }
    // Prefill only when the extension actually names a format. Anything else
    // (`.img`, `.iso`, no extension) resets to auto rather than keeping the
    // previous file's value, which would otherwise be posted as a claim about
    // this one.
    const ext = file.name.split(".").pop()?.toLowerCase();
    const named = DISK_FORMATS.find((f) => f === ext);
    setFormat(named ?? "auto");
  };

  // --- Derived per-tab state -------------------------------------------------

  const trimmedURL = sourceURL.trim();
  const urlValid = /^https?:\/\/.+/i.test(trimmedURL);
  const guessedFormat = guessFormatFromURL(trimmedURL);
  const checksumValid = checksum.trim() === "" || isValidChecksum(checksum);

  const versionFor = (distro: CloudImageDistro): CloudImageVersion => {
    const label = versionByDistro[distro.id];
    return (
      distro.versions.find((v) => v.label === label) ?? distro.versions[0]
    );
  };

  const selectedDistro =
    CLOUD_IMAGE_DISTROS.find((d) => d.id === selectedDistroId) ?? null;
  const selectedVersion = selectedDistro ? versionFor(selectedDistro) : null;
  const selectedCatalogURL = selectedVersion?.urls[architecture];

  let disabled: boolean;
  let submitLabel: string;
  let hint: string;
  if (tab === "upload") {
    disabled = !selectedFile;
    submitLabel = "Upload image";
    hint = !selectedFile
      ? "Select a disk image to continue"
      : format === "auto"
        ? `Format detected on upload · ${architecture}`
        : `${format} · ${architecture}`;
  } else if (tab === "url") {
    disabled = !urlValid || !name || !checksumValid;
    submitLabel = "Import from URL";
    hint = !urlValid
      ? "Enter a valid image URL"
      : !checksumValid
        ? "Checksum must be 64 hex characters"
        : guessedFormat === "auto"
          ? `Format detected on download · ${architecture}`
          : `Detected ${guessedFormat} · ${architecture}`;
  } else {
    disabled = !selectedDistro || !selectedCatalogURL;
    submitLabel = "Download image";
    hint =
      selectedDistro && selectedVersion
        ? selectedCatalogURL
          ? `${selectedDistro.name} ${selectedVersion.label} · ${selectedVersion.size}`
          : `${selectedDistro.name} ${selectedVersion.label} has no ${architecture} build`
        : "Choose an image to download";
  }

  // --- Submit ----------------------------------------------------------------

  const runSubmit = async (fn: () => Promise<unknown>) => {
    setIsSubmitting(true);
    setError(null);
    try {
      await fn();
      resetForm();
      setOpen(false);
      onSuccess?.();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Something went wrong");
    } finally {
      setIsSubmitting(false);
    }
  };

  const handleSubmit = () => {
    if (disabled || isSubmitting) return;

    if (tab === "upload" && selectedFile) {
      setUploadProgress(0);
      void runSubmit(() =>
        uploadImage.mutateAsync({
          file: selectedFile,
          metadata: {
            name: name || selectedFile.name,
            architecture,
            // Omitted on auto so the server detects rather than being handed a
            // claim; it only overrides detection when told a format explicitly.
            format: format === "auto" ? undefined : format,
          },
          onProgress: setUploadProgress,
        }),
      );
      return;
    }

    if (tab === "url") {
      void runSubmit(() =>
        createFromURL.mutateAsync({
          name,
          architecture,
          sourceURL: trimmedURL,
          checksum: checksum.trim() ? checksum.trim().toLowerCase() : undefined,
        }),
      );
      return;
    }

    if (selectedDistro && selectedVersion && selectedCatalogURL) {
      void runSubmit(() =>
        createFromURL.mutateAsync({
          name: catalogImageName(selectedDistro, selectedVersion),
          description: `${selectedDistro.name} ${selectedVersion.label}`,
          architecture,
          sourceURL: selectedCatalogURL,
        }),
      );
    }
  };

  // --- Shared pieces ---------------------------------------------------------

  const archToggle = (
    <div className="flex gap-2">
      {ARCHITECTURES.map((arch) => {
        const on = architecture === arch;
        return (
          <button
            key={arch}
            type="button"
            onClick={() => setArchitecture(arch)}
            style={on ? { borderColor: ACCENT } : undefined}
            className={cn(
              "flex h-[38px] flex-1 items-center justify-center gap-2 rounded-[9px] border font-mono text-[12.5px] font-semibold transition",
              on
                ? "bg-[#eef4fd] text-[#1f5aa8] dark:bg-[#3c87dd]/15 dark:text-[#8ab7ec]"
                : "border-input bg-card text-muted-foreground hover:border-ring",
            )}
          >
            <span
              className="h-[7px] w-[7px] rounded-full"
              style={{ background: on ? ACCENT : "var(--input)" }}
            />
            {arch}
          </button>
        );
      })}
    </div>
  );

  const tabDefs = [
    { key: "upload", label: "Upload disk", icon: Upload },
    { key: "url", label: "From URL", icon: LinkIcon },
    { key: "popular", label: "Popular images", icon: Star },
  ];

  return (
    <Dialog open={open} onOpenChange={handleOpenChange}>
      <DialogTrigger asChild>
        <Button className="bg-primary hover:bg-primary/90">
          <Upload className="mr-2 h-4 w-4" />
          Add Image
        </Button>
      </DialogTrigger>

      <DialogContent
        showCloseButton={false}
        className="flex max-h-[calc(100vh-64px)] flex-col gap-0 overflow-hidden rounded-2xl border-border bg-card p-0 text-foreground sm:max-w-[672px]"
      >
        {/* header */}
        <DialogHeader className="flex-row items-start gap-3.5 space-y-0 px-[22px] pt-5 text-left">
          <div className="flex h-[38px] w-[38px] flex-none items-center justify-center rounded-[10px] border border-border bg-muted text-foreground">
            <svg
              width="19"
              height="19"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              strokeWidth="1.7"
              aria-hidden="true"
            >
              <rect x="3" y="4" width="18" height="12" rx="2.2" />
              <circle cx="8" cy="9" r="1.6" />
              <path d="M3 14l4.5-4 3 2.6L15 8l6 5.5" />
              <path d="M12 19v2M8 21h8" />
            </svg>
          </div>
          <div className="min-w-0 flex-1 pt-px">
            <DialogTitle className="text-[17px] font-bold tracking-[-0.3px]">
              Add image
            </DialogTitle>
            <DialogDescription className="mt-[3px] text-[12.5px] leading-[1.4] text-muted-foreground">
              Bring a disk image into your organization&apos;s image library.
            </DialogDescription>
          </div>
          <DialogClose asChild>
            <button
              type="button"
              className="flex h-[30px] w-[30px] flex-none items-center justify-center rounded-lg border border-border bg-card text-muted-foreground transition hover:bg-muted hover:text-foreground"
            >
              <X className="h-[15px] w-[15px]" />
              <span className="sr-only">Close</span>
            </button>
          </DialogClose>
        </DialogHeader>

        <Tabs
          value={tab}
          onValueChange={setTab}
          className="min-h-0 flex-1 gap-0"
        >
          {/* tabs */}
          <TabsList className="h-auto w-full justify-start gap-0.5 rounded-none border-b border-border bg-transparent p-0 px-[22px] pt-4">
            {tabDefs.map(({ key, label, icon: Icon }) => (
              <TabsTrigger
                key={key}
                value={key}
                className="relative h-auto flex-none gap-2 rounded-none border-0 bg-transparent px-3 pb-[13px] pt-2 text-[13px] font-semibold text-muted-foreground shadow-none transition data-[state=active]:bg-transparent data-[state=active]:text-foreground data-[state=active]:shadow-none dark:data-[state=active]:bg-transparent dark:data-[state=active]:border-0"
              >
                <Icon className="h-4 w-4" />
                {label}
                {tab === key && (
                  <span className="absolute inset-x-1.5 -bottom-px h-0.5 rounded-sm bg-foreground" />
                )}
              </TabsTrigger>
            ))}
          </TabsList>

          <div className="min-h-0 flex-1 overflow-y-auto p-[22px]">
            {/* ---- Upload disk ---- */}
            <TabsContent value="upload" className="mt-0">
              <input
                ref={fileInputRef}
                type="file"
                accept=".qcow2,.img,.raw,.iso,.vmdk,.vhd,.vhdx"
                onChange={(e) => acceptFile(e.target.files?.[0])}
                className="hidden"
              />

              {!selectedFile ? (
                <div
                  onClick={() => fileInputRef.current?.click()}
                  onDragOver={(e) => {
                    e.preventDefault();
                    setDragging(true);
                  }}
                  onDragLeave={(e) => {
                    e.preventDefault();
                    setDragging(false);
                  }}
                  onDrop={(e) => {
                    e.preventDefault();
                    setDragging(false);
                    acceptFile(e.dataTransfer.files?.[0]);
                  }}
                  style={dragging ? { borderColor: ACCENT } : undefined}
                  className={cn(
                    "flex cursor-pointer flex-col items-center gap-2.5 rounded-xl border-[1.5px] border-dashed px-5 py-[34px] text-center transition",
                    dragging
                      ? "bg-[#f0f6ff] dark:bg-[#3c87dd]/10"
                      : "border-input bg-muted/40",
                  )}
                >
                  <div className="flex h-[46px] w-[46px] items-center justify-center rounded-xl border border-border bg-card text-muted-foreground shadow-sm">
                    <Upload className="h-[22px] w-[22px]" strokeWidth={1.7} />
                  </div>
                  <div>
                    <div className="text-[13.5px] font-semibold text-foreground">
                      Drop a disk image here, or{" "}
                      <span style={{ color: ACCENT }}>browse</span>
                    </div>
                    <div className="mt-1 text-xs text-muted-foreground">
                      qcow2 · raw · vmdk · vhd · vhdx
                    </div>
                  </div>
                </div>
              ) : (
                <div className="flex items-center gap-3 rounded-xl border border-border bg-muted/40 px-4 py-[15px]">
                  <div
                    className="flex h-10 w-10 flex-none items-center justify-center rounded-[9px] border bg-[#eef4fd] dark:bg-[#3c87dd]/15"
                    style={{ borderColor: "rgba(60,135,221,0.25)", color: ACCENT }}
                  >
                    <svg
                      width="20"
                      height="20"
                      viewBox="0 0 24 24"
                      fill="none"
                      stroke="currentColor"
                      strokeWidth="1.6"
                      aria-hidden="true"
                    >
                      <rect x="4" y="7" width="16" height="10" rx="2" />
                      <path d="M4 12h16" />
                      <circle cx="7.5" cy="14.5" r="1" fill="currentColor" stroke="none" />
                    </svg>
                  </div>
                  <div className="min-w-0 flex-1">
                    <div className="truncate font-mono text-[13px] font-semibold">
                      {selectedFile.name}
                    </div>
                    <div className="mt-0.5 font-mono text-[11.5px] text-muted-foreground">
                      {(selectedFile.size / 1048576).toFixed(1)} MB · ready to upload
                    </div>
                  </div>
                  <button
                    type="button"
                    onClick={() => setSelectedFile(null)}
                    className="flex h-7 w-7 flex-none items-center justify-center rounded-[7px] border border-border bg-card text-muted-foreground transition hover:bg-muted hover:text-destructive"
                  >
                    <X className="h-3.5 w-3.5" />
                    <span className="sr-only">Remove file</span>
                  </button>
                </div>
              )}

              <div className="mt-[18px] grid grid-cols-2 gap-3.5">
                <div>
                  <label htmlFor="upload-name" className={LABEL_CLASS}>
                    Image name
                  </label>
                  <input
                    id="upload-name"
                    value={name}
                    onChange={(e) => setName(e.target.value)}
                    placeholder="my-custom-image"
                    className={FIELD_CLASS}
                  />
                </div>
                <div>
                  <label htmlFor="upload-format" className={LABEL_CLASS}>
                    Disk format
                  </label>
                  <select
                    id="upload-format"
                    value={format}
                    onChange={(e) => setFormat(e.target.value as FormatChoice)}
                    className={cn(FIELD_CLASS, "cursor-pointer")}
                  >
                    <option value="auto">auto (detect)</option>
                    {DISK_FORMATS.map((f) => (
                      <option key={f} value={f}>
                        {f}
                      </option>
                    ))}
                  </select>
                </div>
              </div>

              <div className="mt-4">
                <span className={LABEL_CLASS}>Architecture</span>
                {archToggle}
              </div>

              {isSubmitting && uploadProgress > 0 && uploadProgress < 100 && (
                <div className="mt-4 space-y-1">
                  <div className="flex justify-between text-xs text-muted-foreground">
                    <span>Uploading…</span>
                    <span>{uploadProgress}%</span>
                  </div>
                  <div className="h-2 overflow-hidden rounded-full bg-muted">
                    <div
                      className="h-full transition-all duration-300"
                      style={{ width: `${uploadProgress}%`, background: ACCENT }}
                    />
                  </div>
                </div>
              )}
            </TabsContent>

            {/* ---- From URL ---- */}
            <TabsContent value="url" className="mt-0">
              <label htmlFor="source-url" className={LABEL_CLASS}>
                Image URL
              </label>
              <div
                className={cn(
                  "flex h-10 items-center gap-2 rounded-[9px] border bg-card px-3 transition focus-within:border-[#3c87dd] focus-within:shadow-[0_0_0_3px_rgba(60,135,221,0.14)]",
                  trimmedURL && !urlValid ? "border-destructive/50" : "border-input",
                )}
              >
                <LinkIcon className="h-[15px] w-[15px] flex-none text-muted-foreground" />
                <input
                  id="source-url"
                  type="url"
                  value={sourceURL}
                  onChange={(e) => setSourceURL(e.target.value)}
                  placeholder="https://cloud-images.example.com/disk.qcow2"
                  className="min-w-0 flex-1 border-none bg-transparent font-mono text-[13px] font-medium text-foreground outline-none"
                />
                {urlValid && (
                  <span
                    title={
                      guessedFormat === "auto"
                        ? "Format will be detected from the file itself"
                        : `Format inferred from the file extension`
                    }
                    className="flex flex-none items-center rounded-full bg-emerald-50 px-2.5 py-0.5 font-mono text-[11px] font-semibold text-emerald-700 dark:bg-emerald-500/15 dark:text-emerald-400"
                  >
                    {guessedFormat}
                  </span>
                )}
              </div>
              <p className="mt-2 text-xs leading-[1.5] text-muted-foreground">
                Strato streams the image directly from the source. HTTP(S)
                endpoints are supported.
              </p>

              <div className="mt-[18px] grid grid-cols-2 gap-3.5">
                <div>
                  <label htmlFor="url-name" className={LABEL_CLASS}>
                    Image name
                  </label>
                  <input
                    id="url-name"
                    value={name}
                    onChange={(e) => setName(e.target.value)}
                    placeholder="ubuntu-24-04-base"
                    className={FIELD_CLASS}
                  />
                </div>
                <div>
                  <label htmlFor="url-arch" className={LABEL_CLASS}>
                    Architecture
                  </label>
                  <select
                    id="url-arch"
                    value={architecture}
                    onChange={(e) =>
                      setArchitecture(e.target.value as CPUArchitecture)
                    }
                    className={cn(FIELD_CLASS, "cursor-pointer")}
                  >
                    {ARCHITECTURES.map((arch) => (
                      <option key={arch} value={arch}>
                        {arch}
                      </option>
                    ))}
                  </select>
                </div>
              </div>

              <div className="mt-4">
                <label htmlFor="url-checksum" className={LABEL_CLASS}>
                  SHA-256 checksum{" "}
                  <span className="font-medium text-muted-foreground/70">
                    · optional
                  </span>
                </label>
                <input
                  id="url-checksum"
                  value={checksum}
                  onChange={(e) => setChecksum(e.target.value)}
                  placeholder="verify integrity after download"
                  spellCheck={false}
                  className={cn(
                    FIELD_CLASS,
                    "text-[12.5px]",
                    !checksumValid && "border-destructive/50",
                  )}
                />
                {!checksumValid && (
                  <p className="mt-1.5 text-xs text-destructive">
                    Must be 64 hexadecimal characters.
                  </p>
                )}
              </div>
            </TabsContent>

            {/* ---- Popular images ---- */}
            <TabsContent value="popular" className="mt-0">
              {/* The mock has no architecture control here, which would silently
                  pin the catalog to x86_64 — reuse the upload tab's toggle. */}
              <div className="mb-4">
                <span className={LABEL_CLASS}>Architecture</span>
                {archToggle}
              </div>

              <div className="flex flex-col gap-[9px]">
                {CLOUD_IMAGE_DISTROS.map((distro) => {
                  const version = versionFor(distro);
                  const on = selectedDistroId === distro.id;
                  const available = Boolean(version.urls[architecture]);
                  return (
                    <div
                      key={distro.id}
                      role="radio"
                      aria-checked={on}
                      tabIndex={0}
                      onClick={() => setSelectedDistroId(distro.id)}
                      onKeyDown={(e) => {
                        if (e.key === " " || e.key === "Enter") {
                          e.preventDefault();
                          setSelectedDistroId(distro.id);
                        }
                      }}
                      style={on ? { borderColor: ACCENT } : undefined}
                      className={cn(
                        "flex cursor-pointer items-center gap-3.5 rounded-xl border px-3.5 py-[13px] transition",
                        on
                          ? "bg-[#f6faff] dark:bg-[#3c87dd]/10"
                          : "border-border bg-card hover:border-ring",
                        !available && "opacity-55",
                      )}
                    >
                      <div
                        className="flex h-10 w-10 flex-none items-center justify-center rounded-[10px] font-mono text-lg font-extrabold text-white"
                        style={{ background: distro.color }}
                        aria-hidden="true"
                      >
                        {distro.logo}
                      </div>

                      <div className="min-w-0 flex-1">
                        <div className="flex items-center gap-2">
                          <span className="text-[13.5px] font-bold">
                            {distro.name}
                          </span>
                          <span className="rounded-[5px] bg-muted px-1.5 py-px font-mono text-[10.5px] font-semibold text-muted-foreground">
                            {available ? version.size : `no ${architecture}`}
                          </span>
                        </div>
                        <div className="mt-0.5 text-xs text-muted-foreground">
                          {distro.description}
                        </div>
                      </div>

                      <select
                        aria-label={`${distro.name} version`}
                        value={version.label}
                        onClick={(e) => e.stopPropagation()}
                        onChange={(e) =>
                          setVersionByDistro((prev) => ({
                            ...prev,
                            [distro.id]: e.target.value,
                          }))
                        }
                        className="h-[34px] flex-none cursor-pointer rounded-lg border border-input bg-card px-2.5 font-mono text-xs font-semibold text-foreground outline-none focus:border-[#3c87dd]"
                      >
                        {distro.versions.map((v) => (
                          <option key={v.label} value={v.label}>
                            {v.label}
                          </option>
                        ))}
                      </select>

                      <span
                        className="flex h-5 w-5 flex-none items-center justify-center rounded-full border-2"
                        style={{
                          borderColor: on ? ACCENT : "var(--input)",
                          background: on ? ACCENT : "transparent",
                        }}
                      >
                        <span
                          className="h-2 w-2 rounded-full"
                          style={{ background: on ? "#fff" : "transparent" }}
                        />
                      </span>
                    </div>
                  );
                })}
              </div>
            </TabsContent>

            {error && <p className="mt-4 text-sm text-destructive">{error}</p>}
          </div>
        </Tabs>

        {/* footer */}
        <div className="flex items-center gap-3 border-t border-border bg-muted/30 px-[22px] py-[15px]">
          <div className="flex min-w-0 flex-1 items-center gap-2 text-xs text-muted-foreground">
            <Info className="h-3.5 w-3.5 flex-none" />
            <span className="truncate">{hint}</span>
          </div>
          <DialogClose asChild>
            <Button
              variant="outline"
              disabled={isSubmitting}
              className="h-9 rounded-[9px] border-border px-[15px] text-[12.5px] font-semibold"
            >
              Cancel
            </Button>
          </DialogClose>
          <Button
            onClick={handleSubmit}
            disabled={disabled || isSubmitting}
            className="h-9 gap-2 rounded-[9px] bg-primary px-[17px] text-[12.5px] font-semibold hover:bg-primary/90"
          >
            {tab === "upload" ? (
              <Upload className="h-[15px] w-[15px]" />
            ) : (
              <ArrowDownToLine className="h-[15px] w-[15px]" />
            )}
            {isSubmitting ? "Working…" : submitLabel}
          </Button>
        </div>
      </DialogContent>
    </Dialog>
  );
}
