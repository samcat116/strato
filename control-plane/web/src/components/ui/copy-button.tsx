"use client";

import { useState } from "react";
import { Check, Copy } from "lucide-react";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { toast } from "sonner";

interface CopyButtonProps {
  /** The text to write to the clipboard. */
  value: string;
  /** Accessible label / tooltip for the button. */
  label?: string;
  /** Toast message shown on a successful copy. Pass null to suppress the toast. */
  toastMessage?: string | null;
  size?: "sm" | "icon" | "icon-sm" | "icon-lg";
  variant?: "outline" | "ghost";
  className?: string;
}

export function CopyButton({
  value,
  label = "Copy to clipboard",
  toastMessage = "Copied to clipboard",
  size = "icon-sm",
  variant = "ghost",
  className,
}: CopyButtonProps) {
  const [copied, setCopied] = useState(false);

  const handleCopy = async () => {
    try {
      await navigator.clipboard.writeText(value);
      setCopied(true);
      if (toastMessage) toast.success(toastMessage);
      setTimeout(() => setCopied(false), 2000);
    } catch {
      toast.error("Failed to copy to clipboard");
    }
  };

  return (
    <Button
      type="button"
      size={size}
      variant={variant}
      className={cn("shrink-0", className)}
      onClick={handleCopy}
      aria-label={label}
      title={label}
    >
      {copied ? (
        <Check className="h-4 w-4 text-green-600" />
      ) : (
        <Copy className="h-4 w-4" />
      )}
    </Button>
  );
}
