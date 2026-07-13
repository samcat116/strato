"use client";

import { useState } from "react";
import { Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import {
  useCreateSSFStream,
  useUpdateSSFStream,
  ssfStreamErrorMessage,
} from "@/lib/hooks/use-ssf-streams";
import { toast } from "sonner";
import type { SSFStream, UpdateSSFStreamRequest } from "@/types/api";

interface SSFStreamDialogProps {
  orgId: string;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  /** When set, the dialog edits this stream instead of creating one. */
  stream?: SSFStream | null;
}

export function SSFStreamDialog({
  orgId,
  open,
  onOpenChange,
  stream,
}: SSFStreamDialogProps) {
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="bg-card border-border text-foreground max-h-[85vh] overflow-y-auto">
        {/* Radix unmounts the content when closed, so the form below mounts
            fresh on every open and its useState initializers do the prefill. */}
        <StreamForm
          key={stream?.id ?? "create"}
          orgId={orgId}
          stream={stream}
          onOpenChange={onOpenChange}
        />
      </DialogContent>
    </Dialog>
  );
}

function StreamForm({
  orgId,
  stream,
  onOpenChange,
}: {
  orgId: string;
  stream?: SSFStream | null;
  onOpenChange: (open: boolean) => void;
}) {
  const isEdit = !!stream;
  const createStream = useCreateSSFStream(orgId);
  const updateStream = useUpdateSSFStream(orgId);
  const isPending = createStream.isPending || updateStream.isPending;

  const [name, setName] = useState(stream?.name ?? "");
  const [description, setDescription] = useState(stream?.description ?? "");
  const [transmitterURL, setTransmitterURL] = useState(
    stream?.transmitterURL ?? ""
  );
  const [authToken, setAuthToken] = useState("");
  const [deliveryMethod, setDeliveryMethod] = useState<"push" | "poll">(
    stream?.deliveryMethod ?? "push"
  );
  const [expectedIssuer, setExpectedIssuer] = useState(
    stream?.expectedIssuer ?? ""
  );
  const [expectedAudience, setExpectedAudience] = useState(
    stream ? stream.expectedAudience.join(" ") : ""
  );
  const [eventsRequested, setEventsRequested] = useState(
    stream ? stream.eventsRequested.join(" ") : ""
  );

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!name.trim()) {
      toast.error("Please enter a display name for the stream");
      return;
    }
    if (!isEdit && !transmitterURL.trim()) {
      toast.error("Please enter the transmitter URL");
      return;
    }

    const audienceList = expectedAudience.trim().split(/[\s,]+/).filter(Boolean);
    const eventsList = eventsRequested.trim().split(/[\s,]+/).filter(Boolean);

    try {
      if (isEdit && stream) {
        const data: UpdateSSFStreamRequest = {
          name: name.trim(),
          description: description.trim(),
          expectedIssuer: expectedIssuer.trim(),
          expectedAudience: audienceList,
          eventsRequested: eventsList,
        };
        // Blank token means "keep the current one"
        if (authToken.trim()) {
          data.authToken = authToken.trim();
        }
        await updateStream.mutateAsync({ streamId: stream.id, data });
        toast.success(`Stream "${name.trim()}" updated`);
      } else {
        await createStream.mutateAsync({
          name: name.trim(),
          description: description.trim() || undefined,
          transmitterURL: transmitterURL.trim(),
          authToken: authToken.trim() || undefined,
          expectedIssuer: expectedIssuer.trim() || undefined,
          expectedAudience: audienceList.length > 0 ? audienceList : undefined,
          deliveryMethod,
          eventsRequested: eventsList.length > 0 ? eventsList : undefined,
        });
        toast.success(`Stream "${name.trim()}" created`);
      }
      onOpenChange(false);
    } catch (error) {
      toast.error(
        ssfStreamErrorMessage(
          error,
          isEdit ? "Failed to update stream" : "Failed to create stream"
        )
      );
    }
  };

  return (
    <>
      <DialogHeader>
        <DialogTitle>
          {isEdit ? `Edit ${stream?.name}` : "Add SSF Stream"}
        </DialogTitle>
        <DialogDescription className="text-muted-foreground">
          {isEdit
            ? "Update the receiver configuration for this stream"
            : "Receive CAEP/RISC security events (session revocation, credential change, ...) from your identity provider via the Shared Signals Framework"}
        </DialogDescription>
      </DialogHeader>

      <form onSubmit={handleSubmit}>
        <div className="space-y-4 py-4">
          <div className="space-y-2">
            <Label htmlFor="ssfName" className="text-foreground">
              Display Name
            </Label>
            <Input
              id="ssfName"
              placeholder="e.g. Okta security events"
              value={name}
              onChange={(e) => setName(e.target.value)}
              className="bg-background border-border text-foreground"
              disabled={isPending}
            />
          </div>

          <div className="space-y-2">
            <Label htmlFor="ssfDescription" className="text-foreground">
              Description (optional)
            </Label>
            <Input
              id="ssfDescription"
              value={description}
              onChange={(e) => setDescription(e.target.value)}
              className="bg-background border-border text-foreground"
              disabled={isPending}
            />
          </div>

          <div className="space-y-2">
            <Label htmlFor="ssfTransmitterURL" className="text-foreground">
              Transmitter URL
            </Label>
            <Input
              id="ssfTransmitterURL"
              placeholder="https://idp.example.com"
              value={transmitterURL}
              onChange={(e) => setTransmitterURL(e.target.value)}
              className="bg-background border-border text-foreground"
              disabled={isPending || isEdit}
            />
            <p className="text-xs text-muted-foreground">
              {isEdit
                ? "The transmitter cannot be changed after creation — delete the stream and create a new one instead."
                : "Base URL of the transmitter; its configuration is discovered at <URL>/.well-known/ssf-configuration."}
            </p>
          </div>

          <div className="space-y-2">
            <Label htmlFor="ssfAuthToken" className="text-foreground">
              Management API Token{isEdit ? "" : " (optional)"}
            </Label>
            <Input
              id="ssfAuthToken"
              type="password"
              autoComplete="off"
              placeholder={isEdit ? "Leave blank to keep the current token" : ""}
              value={authToken}
              onChange={(e) => setAuthToken(e.target.value)}
              className="bg-background border-border text-foreground font-mono"
              disabled={isPending}
            />
            <p className="text-xs text-muted-foreground">
              Bearer token for the transmitter&apos;s stream-management API,
              issued by your identity provider.
            </p>
          </div>

          <div className="space-y-2">
            <Label htmlFor="ssfDeliveryMethod" className="text-foreground">
              Delivery Method
            </Label>
            {isEdit ? (
              <>
                <Input
                  id="ssfDeliveryMethod"
                  value={deliveryMethod === "push" ? "Push (RFC 8935)" : "Poll (RFC 8936)"}
                  className="bg-muted/50 text-muted-foreground"
                  disabled
                />
                <p className="text-xs text-muted-foreground">
                  The delivery method cannot be changed after creation.
                </p>
              </>
            ) : (
              <>
                <Select
                  value={deliveryMethod}
                  onValueChange={(value) =>
                    setDeliveryMethod(value as "push" | "poll")
                  }
                  disabled={isPending}
                >
                  <SelectTrigger
                    id="ssfDeliveryMethod"
                    className="bg-background border-border text-foreground"
                  >
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="push">Push (RFC 8935)</SelectItem>
                    <SelectItem value="poll">Poll (RFC 8936)</SelectItem>
                  </SelectContent>
                </Select>
                <p className="text-xs text-muted-foreground">
                  Push: the transmitter delivers events to a Strato endpoint.
                  Poll: Strato periodically fetches events from the
                  transmitter.
                </p>
              </>
            )}
          </div>

          <div className="space-y-2">
            <Label htmlFor="ssfExpectedIssuer" className="text-foreground">
              Expected Issuer (optional)
            </Label>
            <Input
              id="ssfExpectedIssuer"
              placeholder="Defaults to the transmitter URL"
              value={expectedIssuer}
              onChange={(e) => setExpectedIssuer(e.target.value)}
              className="bg-background border-border text-foreground"
              disabled={isPending}
            />
            <p className="text-xs text-muted-foreground">
              Expected <code>iss</code> claim of received security event
              tokens.
            </p>
          </div>

          <div className="space-y-2">
            <Label htmlFor="ssfExpectedAudience" className="text-foreground">
              Expected Audience (optional)
            </Label>
            <Input
              id="ssfExpectedAudience"
              placeholder="https://strato.example.com"
              value={expectedAudience}
              onChange={(e) => setExpectedAudience(e.target.value)}
              className="bg-background border-border text-foreground font-mono"
              disabled={isPending}
            />
            <p className="text-xs text-muted-foreground">
              Space-separated <code>aud</code> values accepted in received
              tokens.
            </p>
          </div>

          <div className="space-y-2">
            <Label htmlFor="ssfEventsRequested" className="text-foreground">
              Requested Events (optional)
            </Label>
            <Input
              id="ssfEventsRequested"
              placeholder="https://schemas.openid.net/secevent/caep/event-type/session-revoked"
              value={eventsRequested}
              onChange={(e) => setEventsRequested(e.target.value)}
              className="bg-background border-border text-foreground font-mono"
              disabled={isPending}
            />
            <p className="text-xs text-muted-foreground">
              Space-separated event type URIs. Leave blank to accept the
              transmitter&apos;s default set.
            </p>
          </div>
        </div>

        <DialogFooter>
          <Button
            type="button"
            variant="outline"
            className="border-input"
            onClick={() => onOpenChange(false)}
            disabled={isPending}
          >
            Cancel
          </Button>
          <Button
            type="submit"
            className="bg-primary hover:bg-primary/90"
            disabled={isPending}
          >
            {isPending ? (
              <>
                <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                {isEdit ? "Saving..." : "Creating..."}
              </>
            ) : isEdit ? (
              "Save Changes"
            ) : (
              "Add Stream"
            )}
          </Button>
        </DialogFooter>
      </form>
    </>
  );
}
