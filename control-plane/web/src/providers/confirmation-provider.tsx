"use client";

import { createContext, useCallback, useContext, useEffect, useRef, useState, type ReactNode } from "react";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";

interface ConfirmationOptions {
  title?: string;
  description: string;
  confirmLabel?: string;
}

type Confirm = (options: ConfirmationOptions | string) => Promise<boolean>;

const ConfirmationContext = createContext<Confirm | null>(null);
let mountedConfirm: Confirm | null = null;

/** Use from event handlers that cannot conveniently consume provider context. */
export function confirmAction(options: ConfirmationOptions | string): Promise<boolean> {
  return mountedConfirm?.(options) ?? Promise.resolve(false);
}

export function ConfirmationProvider({ children }: { children: ReactNode }) {
  const [options, setOptions] = useState<ConfirmationOptions | null>(null);
  const resolver = useRef<((confirmed: boolean) => void) | null>(null);

  const settle = useCallback((confirmed: boolean) => {
    resolver.current?.(confirmed);
    resolver.current = null;
    setOptions(null);
  }, []);

  const confirm = useCallback<Confirm>((nextOptions) => {
    resolver.current?.(false);
    setOptions(
      typeof nextOptions === "string"
        ? { description: nextOptions }
        : nextOptions
    );
    return new Promise<boolean>((resolve) => {
      resolver.current = resolve;
    });
  }, []);

  useEffect(() => {
    mountedConfirm = confirm;
    return () => {
      if (mountedConfirm === confirm) mountedConfirm = null;
    };
  }, [confirm]);

  return (
    <ConfirmationContext.Provider value={confirm}>
      {children}
      <Dialog
        open={options !== null}
        onOpenChange={(open) => {
          if (!open) settle(false);
        }}
      >
        <DialogContent showCloseButton={false} className="sm:max-w-md">
          <DialogHeader>
            <DialogTitle>{options?.title ?? "Confirm destructive action"}</DialogTitle>
            <DialogDescription>{options?.description}</DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="outline" onClick={() => settle(false)}>
              Cancel
            </Button>
            <Button variant="destructive" onClick={() => settle(true)}>
              {options?.confirmLabel ?? "Continue"}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </ConfirmationContext.Provider>
  );
}

export function useConfirmation(): Confirm {
  const confirm = useContext(ConfirmationContext);
  if (!confirm) {
    throw new Error("useConfirmation must be used within ConfirmationProvider");
  }
  return confirm;
}
