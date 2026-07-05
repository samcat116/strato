"use client";

import { useMemo, useState } from "react";
import { Loader2, Plus, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Label } from "@/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Skeleton } from "@/components/ui/skeleton";
import {
  useGroupMembers,
  useOrganizationMembers,
  useAddGroupMembers,
  useRemoveGroupMember,
  groupErrorMessage,
} from "@/lib/hooks";
import { toast } from "sonner";
import type { Group } from "@/types/api";

interface ManageGroupMembersDialogProps {
  orgId: string;
  group: Group | null;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  /** Whether the current user can add/remove members (org admin). */
  canManage: boolean;
}

export function ManageGroupMembersDialog({
  orgId,
  group,
  open,
  onOpenChange,
  canManage,
}: ManageGroupMembersDialogProps) {
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="bg-gray-800 border-gray-700 text-gray-100">
        {/* Keyed so per-group state (e.g. the pending member selection) resets
            whenever a different group is opened, rather than leaking across
            groups while this component stays mounted. */}
        {group && (
          <MembersManager
            key={group.id}
            orgId={orgId}
            group={group}
            canManage={canManage}
          />
        )}
      </DialogContent>
    </Dialog>
  );
}

function MembersManager({
  orgId,
  group,
  canManage,
}: {
  orgId: string;
  group: Group;
  canManage: boolean;
}) {
  const { data: members = [], isLoading: isMembersLoading } = useGroupMembers(
    orgId,
    group.id
  );
  const { data: orgMembers = [], isLoading: isOrgMembersLoading } =
    useOrganizationMembers(orgId);
  const addMembers = useAddGroupMembers(orgId, group.id);
  const removeMember = useRemoveGroupMember(orgId, group.id);

  const [selectedUserId, setSelectedUserId] = useState("");
  const [pendingId, setPendingId] = useState<string | null>(null);

  // Org members who aren't already in the group are the add candidates.
  const candidates = useMemo(() => {
    const memberIds = new Set(members.map((m) => m.id));
    return orgMembers.filter((m) => !memberIds.has(m.id));
  }, [orgMembers, members]);

  const handleAdd = async () => {
    // Guard against a stale selection (e.g. the user was added via another
    // path and is no longer a candidate).
    const added = candidates.find((c) => c.id === selectedUserId);
    if (!added) {
      setSelectedUserId("");
      return;
    }
    try {
      await addMembers.mutateAsync([added.id]);
      toast.success(
        `Added ${added.displayName || added.username} to ${group.name}`
      );
      setSelectedUserId("");
    } catch (error) {
      toast.error(groupErrorMessage(error, "Failed to add member"));
    }
  };

  const handleRemove = async (userId: string, label: string) => {
    setPendingId(userId);
    try {
      await removeMember.mutateAsync(userId);
      toast.success(`Removed ${label}`);
    } catch (error) {
      toast.error(groupErrorMessage(error, "Failed to remove member"));
    } finally {
      setPendingId(null);
    }
  };

  return (
    <>
      <DialogHeader>
        <DialogTitle>Manage Members — {group.name}</DialogTitle>
        <DialogDescription className="text-gray-400">
          Add or remove organization members from this group.
        </DialogDescription>
      </DialogHeader>

      <div className="space-y-4 py-2">
        {canManage && (
          <div className="space-y-2">
            <Label className="text-gray-200">Add member</Label>
            <div className="flex gap-2">
              <Select
                value={selectedUserId}
                onValueChange={setSelectedUserId}
                disabled={
                  addMembers.isPending ||
                  isOrgMembersLoading ||
                  candidates.length === 0
                }
              >
                <SelectTrigger className="flex-1 bg-gray-900 border-gray-700 text-gray-100">
                  <SelectValue
                    placeholder={
                      isOrgMembersLoading
                        ? "Loading members..."
                        : candidates.length === 0
                          ? "All members are in this group"
                          : "Select a member"
                    }
                  />
                </SelectTrigger>
                <SelectContent className="bg-gray-800 border-gray-700">
                  {candidates.map((c) => (
                    <SelectItem
                      key={c.id}
                      value={c.id}
                      className="text-gray-100 focus:bg-gray-700 focus:text-gray-100"
                    >
                      {c.displayName || c.username} ({c.email})
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
              <Button
                type="button"
                className="bg-blue-600 hover:bg-blue-700"
                onClick={handleAdd}
                disabled={!selectedUserId || addMembers.isPending}
              >
                {addMembers.isPending ? (
                  <Loader2 className="h-4 w-4 animate-spin" />
                ) : (
                  <Plus className="h-4 w-4" />
                )}
              </Button>
            </div>
          </div>
        )}

        <div className="space-y-2">
          <Label className="text-gray-200">
            Members{members.length > 0 ? ` (${members.length})` : ""}
          </Label>
          {isMembersLoading ? (
            <div className="space-y-2">
              {[...Array(2)].map((_, i) => (
                <Skeleton key={i} className="h-11 w-full bg-gray-700" />
              ))}
            </div>
          ) : members.length === 0 ? (
            <p className="text-sm text-gray-400 py-4 text-center">
              This group has no members yet.
            </p>
          ) : (
            <ul className="divide-y divide-gray-700 rounded-md border border-gray-700 max-h-64 overflow-y-auto">
              {members.map((member) => {
                const label = member.displayName || member.username;
                const isPending = pendingId === member.id;
                return (
                  <li
                    key={member.id}
                    className="flex items-center justify-between px-3 py-2"
                  >
                    <div className="flex flex-col">
                      <span className="text-sm font-medium text-gray-100">
                        {label}
                      </span>
                      <span className="text-xs text-gray-400">
                        {member.email}
                      </span>
                    </div>
                    {canManage && (
                      <Button
                        size="icon-sm"
                        variant="ghost"
                        className="text-gray-400 hover:text-red-400 hover:bg-red-950/30"
                        onClick={() => handleRemove(member.id, label)}
                        disabled={isPending}
                        aria-label={`Remove ${label}`}
                      >
                        {isPending ? (
                          <Loader2 className="h-4 w-4 animate-spin" />
                        ) : (
                          <Trash2 className="h-4 w-4" />
                        )}
                      </Button>
                    )}
                  </li>
                );
              })}
            </ul>
          )}
        </div>
      </div>
    </>
  );
}
