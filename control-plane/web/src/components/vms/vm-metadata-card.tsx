"use client";

import { errorMessage } from "@/lib/errors";

import { useRef, useState, type FormEvent } from "react";
import { KeyRound, Loader2, Pencil, Plus, Tags, Trash2 } from "lucide-react";
import { toast } from "sonner";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Label } from "@/components/ui/label";
import { vmsApi } from "@/lib/api/vms";
import type { VM } from "@/types/api";

interface VMMetadataCardProps {
  vm: VM;
  onUpdated?: () => void;
}

interface EditableTag {
  id: string;
  key: string;
  value: string;
}

function tagsForEditor(tags: Record<string, string>): EditableTag[] {
  return Object.entries(tags)
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([key, value], index) => ({ id: `${index}:${key}`, key, value }));
}

function tagsForRequest(entries: EditableTag[]): Record<string, string> {
  const tags: Record<string, string> = {};
  for (const [index, entry] of entries.entries()) {
    if (!entry.key) {
      throw new Error(`Tag ${index + 1} needs a key`);
    }
    if (Object.hasOwn(tags, entry.key)) {
      throw new Error(`Tag key "${entry.key}" appears more than once`);
    }
    tags[entry.key] = entry.value;
  }
  return tags;
}

function keysForEditor(keys: string[]): string {
  return keys.join("\n");
}

function parseAuthorizedKeys(input: string): string[] {
  return input
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);
}

export function VMMetadataCard({ vm, onUpdated }: VMMetadataCardProps) {
  const [open, setOpen] = useState(false);
  const tagEntries = Object.entries(vm.tags ?? {}).sort(([left], [right]) =>
    left.localeCompare(right)
  );
  const keyCount = vm.sshAuthorizedKeys?.length ?? 0;

  return (
    <>
      <Card className="bg-card border-border">
        <CardHeader className="flex flex-row items-center justify-between space-y-0">
          <div>
            <CardTitle className="text-lg font-semibold text-foreground">
              Instance metadata
            </CardTitle>
            <p className="mt-1 text-sm text-muted-foreground">
              Tags and SSH keys published to this VM.
            </p>
          </div>
          <Button variant="outline" size="sm" onClick={() => setOpen(true)}>
            <Pencil className="mr-2 h-4 w-4" />
            Edit metadata
          </Button>
        </CardHeader>
        <CardContent className="space-y-4">
          <div>
            <div className="mb-2 flex items-center gap-2 text-sm font-medium text-foreground">
              <Tags className="h-4 w-4" />
              Tags
            </div>
            {tagEntries.length ? (
              <div className="flex flex-wrap gap-2">
                {tagEntries.map(([key, value]) => (
                  <Badge key={key} variant="secondary" className="font-mono">
                    {key}={value}
                  </Badge>
                ))}
              </div>
            ) : (
              <p className="text-sm text-muted-foreground">No tags</p>
            )}
          </div>
          <div>
            <div className="flex items-center gap-2 text-sm font-medium text-foreground">
              <KeyRound className="h-4 w-4" />
              Authorized keys
            </div>
            <p className="mt-1 text-sm text-muted-foreground">
              {keyCount === 1 ? "1 key published" : `${keyCount} keys published`}
            </p>
          </div>
        </CardContent>
      </Card>

      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent className="bg-card border-border text-foreground sm:max-w-2xl">
          {open && (
            <VMMetadataForm
              key={`${vm.id}:${vm.updatedAt}`}
              vm={vm}
              onClose={() => setOpen(false)}
              onUpdated={onUpdated}
            />
          )}
        </DialogContent>
      </Dialog>
    </>
  );
}

function VMMetadataForm({
  vm,
  onClose,
  onUpdated,
}: {
  vm: VM;
  onClose: () => void;
  onUpdated?: () => void;
}) {
  const usesIMDS = vm.metadataSource === "imds";
  const [tags, setTags] = useState(() => tagsForEditor(vm.tags ?? {}));
  const nextTagID = useRef(tags.length);
  const [authorizedKeys, setAuthorizedKeys] = useState(() =>
    keysForEditor(vm.sshAuthorizedKeys ?? [])
  );
  const [isLoading, setIsLoading] = useState(false);

  const handleSubmit = async (event: FormEvent) => {
    event.preventDefault();

    let parsedTags: Record<string, string>;
    try {
      parsedTags = tagsForRequest(tags);
    } catch (error) {
      toast.error(errorMessage(error, "Invalid tags"));
      return;
    }

    setIsLoading(true);
    try {
      await vmsApi.patchMetadata(vm.id, {
        tags: parsedTags,
        sshAuthorizedKeys: parseAuthorizedKeys(authorizedKeys),
      });
      toast.success(`Instance metadata for "${vm.name}" updated`);
      onClose();
      onUpdated?.();
    } catch (error) {
      toast.error(
        errorMessage(error, "Failed to update instance metadata")
      );
    } finally {
      setIsLoading(false);
    }
  };

  return (
    <>
      <DialogHeader>
        <DialogTitle>Edit instance metadata</DialogTitle>
        <DialogDescription className="text-muted-foreground">
          Replace the tags and authorized keys published for {vm.name}. Empty
          fields clear the corresponding list.
        </DialogDescription>
      </DialogHeader>
      <form onSubmit={handleSubmit}>
        <div className="space-y-5 py-4">
          <div className="space-y-2">
            <div className="flex items-center justify-between">
              <Label>Tags</Label>
              <Button
                type="button"
                variant="outline"
                size="sm"
                disabled={isLoading || tags.length >= 64}
                onClick={() =>
                  setTags((current) => [
                    ...current,
                    { id: `new:${nextTagID.current++}`, key: "", value: "" },
                  ])
                }
              >
                <Plus className="mr-2 h-4 w-4" />
                Add tag
              </Button>
            </div>
            {tags.length ? (
              <div className="max-h-64 space-y-2 overflow-y-auto pr-1">
                {tags.map((tag, index) => (
                  <div
                    key={tag.id}
                    className="grid grid-cols-[minmax(0,1fr)_minmax(0,1.5fr)_auto] items-start gap-2"
                  >
                    <input
                      value={tag.key}
                      onChange={(event) =>
                        setTags((current) =>
                          current.map((entry) =>
                            entry.id === tag.id
                              ? { ...entry, key: event.target.value }
                              : entry
                          )
                        )
                      }
                      aria-label={`Tag ${index + 1} key`}
                      placeholder="environment"
                      disabled={isLoading}
                      className="w-full rounded-md border border-border bg-background px-3 py-2 font-mono text-sm text-foreground focus:outline-none focus:ring-2 focus:ring-blue-500 disabled:opacity-50"
                    />
                    <textarea
                      value={tag.value}
                      onChange={(event) =>
                        setTags((current) =>
                          current.map((entry) =>
                            entry.id === tag.id
                              ? { ...entry, value: event.target.value }
                              : entry
                          )
                        )
                      }
                      aria-label={`Tag ${index + 1} value`}
                      placeholder="production"
                      rows={1}
                      disabled={isLoading}
                      className="min-h-10 w-full resize-y rounded-md border border-border bg-background px-3 py-2 font-mono text-sm text-foreground focus:outline-none focus:ring-2 focus:ring-blue-500 disabled:opacity-50"
                    />
                    <Button
                      type="button"
                      variant="ghost"
                      size="icon"
                      aria-label={`Remove tag ${index + 1}`}
                      disabled={isLoading}
                      onClick={() =>
                        setTags((current) =>
                          current.filter((entry) => entry.id !== tag.id)
                        )
                      }
                    >
                      <Trash2 className="h-4 w-4" />
                    </Button>
                  </div>
                ))}
              </div>
            ) : (
              <p className="text-sm text-muted-foreground">No tags</p>
            )}
            <p className="text-xs text-muted-foreground">
              Up to 64 key/value pairs. Values may span more than one line.
            </p>
          </div>

          <div className="space-y-2">
            <Label htmlFor="vmMetadataAuthorizedKeys">SSH authorized keys</Label>
            <textarea
              id="vmMetadataAuthorizedKeys"
              value={authorizedKeys}
              onChange={(event) => setAuthorizedKeys(event.target.value)}
              placeholder="ssh-ed25519 AAAA... operator@example"
              rows={7}
              disabled={isLoading}
              className="w-full resize-y rounded-md border border-border bg-background px-3 py-2 font-mono text-xs text-foreground focus:outline-none focus:ring-2 focus:ring-blue-500 disabled:opacity-50"
            />
            <p className="text-xs text-muted-foreground">
              One OpenSSH public key per line.
            </p>
          </div>

          <div className="rounded-md border border-amber-500/40 bg-amber-500/10 p-3 text-sm text-foreground">
            {usesIMDS ? (
              <>
                Strato publishes these changes to instance metadata without
                restarting the VM. cloud-init does not apply a rotated key inside an
                already-running guest; reboot it or explicitly run cloud-init clean
                and re-run cloud-init. Live rotation requires the VM guest agent.
              </>
            ) : (
              <>
                This VM bootstraps from an immutable seed ISO. Strato updates its
                stored and link-local metadata, but cloud-init keeps using the ISO,
                so an SSH key edit will not take effect even after a normal reboot.
                Live rotation requires the VM guest agent.
              </>
            )}
          </div>
        </div>
        <DialogFooter>
          <Button type="button" variant="outline" onClick={onClose} disabled={isLoading}>
            Cancel
          </Button>
          <Button type="submit" disabled={isLoading}>
            {isLoading ? (
              <>
                <Loader2 className="mr-2 h-4 w-4 animate-spin" />
                Saving...
              </>
            ) : (
              "Save metadata"
            )}
          </Button>
        </DialogFooter>
      </form>
    </>
  );
}
