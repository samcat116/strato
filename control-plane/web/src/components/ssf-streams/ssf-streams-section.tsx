"use client";

import { useState } from "react";
import {
  Activity,
  Check,
  Copy,
  Loader2,
  Pencil,
  Plus,
  Power,
  Radio,
  RefreshCw,
  ShieldCheck,
  Trash2,
} from "lucide-react";
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
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { Label } from "@/components/ui/label";
import { Skeleton } from "@/components/ui/skeleton";
import { SSFStreamDialog } from "./ssf-stream-dialog";
import {
  useSSFStreams,
  useUpdateSSFStream,
  useDeleteSSFStream,
  useRegisterSSFStream,
  useVerifySSFStream,
  useSSFStreamStatus,
  usePollSSFStream,
  ssfStreamErrorMessage,
} from "@/lib/hooks/use-ssf-streams";
import { toast } from "sonner";
import type { RegisterSSFStreamResponse, SSFStream } from "@/types/api";

interface SSFStreamsSectionProps {
  orgId: string;
  canManage: boolean;
}

export function SSFStreamsSection({ orgId, canManage }: SSFStreamsSectionProps) {
  const [dialogOpen, setDialogOpen] = useState(false);
  const [editTarget, setEditTarget] = useState<SSFStream | null>(null);
  const [deleteTarget, setDeleteTarget] = useState<SSFStream | null>(null);
  const [registration, setRegistration] =
    useState<RegisterSSFStreamResponse | null>(null);
  const { data: streams = [], isLoading } = useSSFStreams(orgId);
  const updateStream = useUpdateSSFStream(orgId);
  const deleteStream = useDeleteSSFStream(orgId);
  const registerStream = useRegisterSSFStream(orgId);
  const verifyStream = useVerifySSFStream(orgId);
  const streamStatus = useSSFStreamStatus(orgId);
  const pollStream = usePollSSFStream(orgId);
  const [pendingAction, setPendingAction] = useState<{
    id: string;
    action: "toggle" | "register" | "verify" | "status" | "poll";
  } | null>(null);

  const isPending = (stream: SSFStream, action: string) =>
    pendingAction?.id === stream.id && pendingAction.action === action;

  const handleToggleEnabled = async (stream: SSFStream) => {
    setPendingAction({ id: stream.id, action: "toggle" });
    try {
      await updateStream.mutateAsync({
        streamId: stream.id,
        data: { enabled: !stream.enabled },
      });
      toast.success(
        `Stream "${stream.name}" ${stream.enabled ? "disabled" : "enabled"}`
      );
    } catch (error) {
      toast.error(ssfStreamErrorMessage(error, "Failed to update stream"));
    } finally {
      setPendingAction(null);
    }
  };

  const handleRegister = async (stream: SSFStream) => {
    setPendingAction({ id: stream.id, action: "register" });
    try {
      const result = await registerStream.mutateAsync(stream.id);
      if (result.pushToken) {
        setRegistration(result);
      } else {
        toast.success(`Stream "${stream.name}" registered at the transmitter`);
      }
    } catch (error) {
      toast.error(ssfStreamErrorMessage(error, "Failed to register stream"));
    } finally {
      setPendingAction(null);
    }
  };

  const handleVerify = async (stream: SSFStream) => {
    setPendingAction({ id: stream.id, action: "verify" });
    try {
      await verifyStream.mutateAsync(stream.id);
      toast.success(
        "Verification requested — the transmitter will send a verification event"
      );
    } catch (error) {
      toast.error(ssfStreamErrorMessage(error, "Failed to request verification"));
    } finally {
      setPendingAction(null);
    }
  };

  const handleStatus = async (stream: SSFStream) => {
    setPendingAction({ id: stream.id, action: "status" });
    try {
      const status = await streamStatus.mutateAsync(stream.id);
      const reason = status.reason ? ` (${status.reason})` : "";
      toast.info(`Transmitter reports stream status: ${status.status}${reason}`);
    } catch (error) {
      toast.error(ssfStreamErrorMessage(error, "Failed to fetch stream status"));
    } finally {
      setPendingAction(null);
    }
  };

  const handlePoll = async (stream: SSFStream) => {
    setPendingAction({ id: stream.id, action: "poll" });
    try {
      const result = await pollStream.mutateAsync(stream.id);
      const failed = result.failed > 0 ? `, ${result.failed} failed` : "";
      const more = result.moreAvailable ? " — more available" : "";
      toast.success(`Processed ${result.processed} event(s)${failed}${more}`);
    } catch (error) {
      toast.error(ssfStreamErrorMessage(error, "Failed to poll stream"));
    } finally {
      setPendingAction(null);
    }
  };

  const handleDelete = async () => {
    if (!deleteTarget) return;
    try {
      await deleteStream.mutateAsync(deleteTarget.id);
      toast.success(`Stream "${deleteTarget.name}" deleted`);
      setDeleteTarget(null);
    } catch (error) {
      toast.error(ssfStreamErrorMessage(error, "Failed to delete stream"));
    }
  };

  const openCreate = () => {
    setEditTarget(null);
    setDialogOpen(true);
  };

  const openEdit = (stream: SSFStream) => {
    setEditTarget(stream);
    setDialogOpen(true);
  };

  return (
    <Card className="bg-card border-border">
      <CardHeader className="flex flex-row items-center justify-between space-y-0">
        <CardTitle className="text-lg font-semibold text-foreground">
          Security Event Streams (SSF)
        </CardTitle>
        {canManage && (
          <Button
            size="sm"
            className="bg-primary hover:bg-primary/90"
            onClick={openCreate}
          >
            <Plus className="h-4 w-4 mr-2" />
            Add Stream
          </Button>
        )}
      </CardHeader>
      <CardContent>
        <p className="text-sm text-muted-foreground mb-4">
          Shared Signals Framework receiver streams consume CAEP/RISC security
          events from your identity provider — e.g. revoking a member&apos;s
          Strato sessions when their IdP session is revoked or their account is
          disabled. After creating a stream, register it at the transmitter to
          start receiving events.
        </p>

        {isLoading ? (
          <div className="space-y-2">
            {[...Array(2)].map((_, i) => (
              <Skeleton key={i} className="h-12 w-full bg-muted" />
            ))}
          </div>
        ) : streams.length === 0 ? (
          <div className="text-center py-8 text-muted-foreground">
            No SSF streams configured.
            {canManage &&
              " Add one to receive security events from your identity provider."}
          </div>
        ) : (
          <Table>
            <TableHeader className="bg-background">
              <TableRow className="border-border hover:bg-transparent">
                <TableHead className="text-muted-foreground font-medium">
                  Name
                </TableHead>
                <TableHead className="text-muted-foreground font-medium">
                  Transmitter
                </TableHead>
                <TableHead className="text-muted-foreground font-medium">
                  Delivery
                </TableHead>
                <TableHead className="text-muted-foreground font-medium">
                  Status
                </TableHead>
                <TableHead className="text-muted-foreground font-medium">
                  Last Event
                </TableHead>
                {canManage && (
                  <TableHead className="text-muted-foreground font-medium text-right">
                    Actions
                  </TableHead>
                )}
              </TableRow>
            </TableHeader>
            <TableBody className="divide-y divide-border">
              {streams.map((stream) => (
                <TableRow
                  key={stream.id}
                  className="border-border hover:bg-accent/60"
                >
                  <TableCell>
                    <span className="font-medium text-foreground">
                      {stream.name}
                    </span>
                  </TableCell>
                  <TableCell className="text-foreground/80 font-mono text-sm max-w-48 truncate">
                    {stream.transmitterURL}
                  </TableCell>
                  <TableCell>
                    <Badge className="bg-muted text-foreground/80 border-transparent">
                      {stream.deliveryMethod === "push" ? "Push" : "Poll"}
                    </Badge>
                  </TableCell>
                  <TableCell>
                    <div className="flex flex-wrap items-center gap-1">
                      {!stream.enabled ? (
                        <Badge className="bg-muted text-foreground/80 border-transparent">
                          Disabled
                        </Badge>
                      ) : !stream.registered ? (
                        <Badge className="bg-yellow-500/10 text-yellow-700 border-transparent">
                          Not registered
                        </Badge>
                      ) : stream.verifiedAt ? (
                        <Badge className="bg-green-500/10 text-green-700 border-transparent">
                          Verified
                        </Badge>
                      ) : (
                        <Badge className="bg-blue-500/10 text-blue-700 border-transparent">
                          Registered
                        </Badge>
                      )}
                      {stream.lastError && (
                        <Badge
                          className="bg-red-500/10 text-red-700 border-transparent"
                          title={stream.lastError}
                        >
                          Error
                        </Badge>
                      )}
                    </div>
                  </TableCell>
                  <TableCell className="text-muted-foreground text-sm">
                    {stream.lastEventAt
                      ? new Date(stream.lastEventAt).toLocaleString()
                      : "—"}
                  </TableCell>
                  {canManage && (
                    <TableCell className="text-right">
                      <div className="flex items-center justify-end gap-1">
                        {!stream.registered && stream.enabled && (
                          <Button
                            size="icon-sm"
                            variant="ghost"
                            className="text-muted-foreground hover:text-foreground"
                            onClick={() => handleRegister(stream)}
                            disabled={isPending(stream, "register")}
                            aria-label={`Register ${stream.name} at the transmitter`}
                            title="Register at transmitter"
                          >
                            {isPending(stream, "register") ? (
                              <Loader2 className="h-4 w-4 animate-spin" />
                            ) : (
                              <Radio className="h-4 w-4" />
                            )}
                          </Button>
                        )}
                        {stream.registered && (
                          <>
                            <Button
                              size="icon-sm"
                              variant="ghost"
                              className="text-muted-foreground hover:text-foreground"
                              onClick={() => handleVerify(stream)}
                              disabled={isPending(stream, "verify")}
                              aria-label={`Request verification for ${stream.name}`}
                              title="Request verification event"
                            >
                              {isPending(stream, "verify") ? (
                                <Loader2 className="h-4 w-4 animate-spin" />
                              ) : (
                                <ShieldCheck className="h-4 w-4" />
                              )}
                            </Button>
                            <Button
                              size="icon-sm"
                              variant="ghost"
                              className="text-muted-foreground hover:text-foreground"
                              onClick={() => handleStatus(stream)}
                              disabled={isPending(stream, "status")}
                              aria-label={`Check transmitter status of ${stream.name}`}
                              title="Check transmitter status"
                            >
                              {isPending(stream, "status") ? (
                                <Loader2 className="h-4 w-4 animate-spin" />
                              ) : (
                                <Activity className="h-4 w-4" />
                              )}
                            </Button>
                          </>
                        )}
                        {stream.registered &&
                          stream.enabled &&
                          stream.deliveryMethod === "poll" && (
                            <Button
                              size="icon-sm"
                              variant="ghost"
                              className="text-muted-foreground hover:text-foreground"
                              onClick={() => handlePoll(stream)}
                              disabled={isPending(stream, "poll")}
                              aria-label={`Poll ${stream.name} now`}
                              title="Poll now"
                            >
                              {isPending(stream, "poll") ? (
                                <Loader2 className="h-4 w-4 animate-spin" />
                              ) : (
                                <RefreshCw className="h-4 w-4" />
                              )}
                            </Button>
                          )}
                        <Button
                          size="icon-sm"
                          variant="ghost"
                          className="text-muted-foreground hover:text-foreground"
                          onClick={() => handleToggleEnabled(stream)}
                          disabled={isPending(stream, "toggle")}
                          aria-label={
                            stream.enabled
                              ? `Disable ${stream.name}`
                              : `Enable ${stream.name}`
                          }
                          title={stream.enabled ? "Disable" : "Enable"}
                        >
                          {isPending(stream, "toggle") ? (
                            <Loader2 className="h-4 w-4 animate-spin" />
                          ) : (
                            <Power className="h-4 w-4" />
                          )}
                        </Button>
                        <Button
                          size="icon-sm"
                          variant="ghost"
                          className="text-muted-foreground hover:text-foreground"
                          onClick={() => openEdit(stream)}
                          aria-label={`Edit ${stream.name}`}
                          title="Edit"
                        >
                          <Pencil className="h-4 w-4" />
                        </Button>
                        <Button
                          size="icon-sm"
                          variant="ghost"
                          className="text-muted-foreground hover:text-red-600 hover:bg-red-500/10"
                          onClick={() => setDeleteTarget(stream)}
                          aria-label={`Delete ${stream.name}`}
                          title="Delete"
                        >
                          <Trash2 className="h-4 w-4" />
                        </Button>
                      </div>
                    </TableCell>
                  )}
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
      </CardContent>

      {canManage && (
        <SSFStreamDialog
          orgId={orgId}
          open={dialogOpen}
          onOpenChange={setDialogOpen}
          stream={editTarget}
        />
      )}

      {/* One-time push token reveal after registration */}
      <PushTokenDialog
        registration={registration}
        onClose={() => setRegistration(null)}
      />

      {/* Delete confirmation dialog */}
      <Dialog
        open={!!deleteTarget}
        onOpenChange={(open) => {
          if (!open) setDeleteTarget(null);
        }}
      >
        <DialogContent className="bg-card border-border text-foreground">
          <DialogHeader>
            <DialogTitle>Delete {deleteTarget?.name}?</DialogTitle>
            <DialogDescription className="text-muted-foreground">
              The stream is also deleted at the transmitter, and security
              events from it will no longer be received or acted on. This
              cannot be undone.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button
              variant="outline"
              className="border-input"
              onClick={() => setDeleteTarget(null)}
              disabled={deleteStream.isPending}
            >
              Cancel
            </Button>
            <Button
              variant="destructive"
              onClick={handleDelete}
              disabled={deleteStream.isPending}
            >
              {deleteStream.isPending ? (
                <Loader2 className="h-4 w-4 animate-spin" />
              ) : (
                <Trash2 className="h-4 w-4" />
              )}
              Delete
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </Card>
  );
}

function PushTokenDialog({
  registration,
  onClose,
}: {
  registration: RegisterSSFStreamResponse | null;
  onClose: () => void;
}) {
  const [copiedField, setCopiedField] = useState<"token" | "endpoint" | null>(
    null
  );

  const handleCopy = async (field: "token" | "endpoint", value: string) => {
    await navigator.clipboard.writeText(value);
    setCopiedField(field);
    toast.success(
      field === "token" ? "Token copied to clipboard" : "Endpoint copied to clipboard"
    );
    setTimeout(() => setCopiedField(null), 2000);
  };

  return (
    <Dialog
      open={!!registration}
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
    >
      <DialogContent className="bg-card border-border text-foreground">
        <DialogHeader>
          <DialogTitle>Stream Registered</DialogTitle>
          <DialogDescription className="text-muted-foreground">
            Copy the delivery token now — it won&apos;t be shown again
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-4 py-4">
          {registration?.stream.pushEndpoint && (
            <div className="p-4 bg-background rounded-lg border border-border">
              <Label className="text-muted-foreground text-sm">
                Push delivery endpoint
              </Label>
              <div className="flex items-center gap-2 mt-2">
                <code className="flex-1 min-w-0 p-2 bg-gray-950 rounded text-sm text-green-400 font-mono overflow-x-auto whitespace-nowrap">
                  {registration.stream.pushEndpoint}
                </code>
                <Button
                  size="sm"
                  variant="outline"
                  className="border-input shrink-0"
                  onClick={() =>
                    handleCopy("endpoint", registration.stream.pushEndpoint!)
                  }
                >
                  {copiedField === "endpoint" ? (
                    <Check className="h-4 w-4 text-green-600" />
                  ) : (
                    <Copy className="h-4 w-4" />
                  )}
                </Button>
              </div>
            </div>
          )}

          <div className="p-4 bg-background rounded-lg border border-border">
            <Label className="text-muted-foreground text-sm">
              Delivery bearer token
            </Label>
            <div className="flex items-center gap-2 mt-2">
              <code className="flex-1 min-w-0 p-2 bg-gray-950 rounded text-sm text-green-400 font-mono overflow-x-auto whitespace-nowrap">
                {registration?.pushToken}
              </code>
              <Button
                size="sm"
                variant="outline"
                className="border-input shrink-0"
                onClick={() =>
                  registration?.pushToken &&
                  handleCopy("token", registration.pushToken)
                }
              >
                {copiedField === "token" ? (
                  <Check className="h-4 w-4 text-green-600" />
                ) : (
                  <Copy className="h-4 w-4" />
                )}
              </Button>
            </div>
          </div>

          <div className="p-4 bg-blue-500/10 rounded-lg border border-blue-500/30">
            <p className="text-sm text-blue-800">
              <strong>Important:</strong> Configure the endpoint and token in
              your identity provider&apos;s SSF transmitter now. The
              transmitter authenticates its deliveries with this bearer token,
              which cannot be retrieved again after you close this dialog.
            </p>
          </div>

          <DialogFooter>
            <Button className="bg-primary hover:bg-primary/90" onClick={onClose}>
              Done
            </Button>
          </DialogFooter>
        </div>
      </DialogContent>
    </Dialog>
  );
}
