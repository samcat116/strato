import { Loader2 } from "lucide-react";

import { Button } from "@/components/ui/button";
import { DialogFooter } from "@/components/ui/dialog";

interface DialogSubmitFooterProps {
  submitLabel: string;
  pendingLabel: string;
  isPending: boolean;
  disabled?: boolean;
  onCancel: () => void;
}

export function DialogSubmitFooter({
  submitLabel,
  pendingLabel,
  isPending,
  disabled = false,
  onCancel,
}: DialogSubmitFooterProps) {
  return (
    <DialogFooter>
      <Button
        type="button"
        variant="outline"
        onClick={onCancel}
        className="border-input text-foreground/80 hover:bg-accent"
        disabled={isPending}
      >
        Cancel
      </Button>
      <Button
        type="submit"
        className="bg-primary hover:bg-primary/90"
        disabled={isPending || disabled}
      >
        {isPending ? (
          <>
            <Loader2 className="mr-2 h-4 w-4 animate-spin" />
            {pendingLabel}
          </>
        ) : (
          submitLabel
        )}
      </Button>
    </DialogFooter>
  );
}
