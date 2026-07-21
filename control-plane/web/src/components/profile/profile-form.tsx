"use client";

import { useState } from "react";
import { Loader2, Save } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { UserAvatar } from "@/components/ui/user-avatar";
import { useUpdateUser, userErrorMessage } from "@/lib/hooks";
import { useAuth } from "@/providers";
import { toast } from "sonner";
import type { User } from "@/types/api";

function seedForm(user: User | null) {
  return {
    username: user?.username ?? "",
    displayName: user?.displayName ?? "",
    email: user?.email ?? "",
  };
}

/**
 * Account details for the signed-in user. SCIM-provisioned accounts are shown
 * read-only: the server rejects edits because the next directory sync would
 * overwrite them anyway.
 */
export function ProfileForm() {
  const { user, refresh } = useAuth();
  const updateUser = useUpdateUser();

  const [form, setForm] = useState(() => seedForm(user));
  // The session resolves asynchronously, so seed the inputs during render once
  // the user (or a different user) arrives rather than in an effect, which
  // would render an empty form first and then cascade.
  const [seededFor, setSeededFor] = useState(user?.id);
  if (user && user.id !== seededFor) {
    setSeededFor(user.id);
    setForm(seedForm(user));
  }

  const managedExternally = user?.source === "scim";
  const dirty =
    !!user &&
    (form.username !== user.username ||
      form.displayName !== user.displayName ||
      form.email !== user.email);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!user?.id || !dirty) return;

    try {
      await updateUser.mutateAsync({
        id: user.id,
        data: {
          username: form.username.trim(),
          displayName: form.displayName.trim(),
          email: form.email.trim(),
        },
      });
      // Pull the session back through so the sidebar, avatar and any other
      // consumer of `user` reflect the change immediately.
      await refresh();
      toast.success("Profile updated");
    } catch (error) {
      toast.error(userErrorMessage(error, "Failed to update profile"));
    }
  };

  return (
    <Card className="bg-card border-border">
      <CardHeader>
        <CardTitle className="text-lg font-semibold text-foreground">
          Account
        </CardTitle>
      </CardHeader>
      <CardContent>
        <form onSubmit={handleSubmit} className="space-y-5">
          <div className="flex items-center gap-3">
            <UserAvatar
              email={form.email || user?.email}
              name={form.displayName || form.username}
              size={44}
            />
            <p className="text-sm text-muted-foreground">
              Your avatar comes from Gravatar, based on your email address.
            </p>
          </div>

          <div className="grid gap-4 sm:grid-cols-2">
            <div className="space-y-2">
              <Label htmlFor="username">Username</Label>
              <Input
                id="username"
                value={form.username}
                disabled={managedExternally}
                onChange={(e) =>
                  setForm((prev) => ({ ...prev, username: e.target.value }))
                }
              />
              <p className="text-xs text-muted-foreground">
                Used to sign in. Letters, numbers, dots, underscores and hyphens.
              </p>
            </div>

            <div className="space-y-2">
              <Label htmlFor="displayName">Display name</Label>
              <Input
                id="displayName"
                value={form.displayName}
                disabled={managedExternally}
                onChange={(e) =>
                  setForm((prev) => ({ ...prev, displayName: e.target.value }))
                }
              />
              <p className="text-xs text-muted-foreground">
                How your name appears throughout Strato.
              </p>
            </div>
          </div>

          <div className="space-y-2">
            <Label htmlFor="email">Email</Label>
            <Input
              id="email"
              type="email"
              value={form.email}
              disabled={managedExternally}
              onChange={(e) =>
                setForm((prev) => ({ ...prev, email: e.target.value }))
              }
            />
          </div>

          {managedExternally && (
            <p className="text-sm text-muted-foreground">
              This account is provisioned by your identity provider, so these
              details are managed there.
            </p>
          )}

          <div className="flex justify-end">
            <Button
              type="submit"
              disabled={!dirty || managedExternally || updateUser.isPending}
            >
              {updateUser.isPending ? (
                <Loader2 className="mr-2 h-4 w-4 animate-spin" />
              ) : (
                <Save className="mr-2 h-4 w-4" />
              )}
              Save changes
            </Button>
          </div>
        </form>
      </CardContent>
    </Card>
  );
}
