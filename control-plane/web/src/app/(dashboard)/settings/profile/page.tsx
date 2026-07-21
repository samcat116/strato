"use client";

import { PasskeysSection, ProfileForm } from "@/components/profile";

export default function ProfilePage() {
  return (
    <div className="mx-auto max-w-4xl space-y-6">
      <div>
        <h2 className="text-2xl font-semibold text-foreground">Your profile</h2>
        <p className="text-muted-foreground">
          Update your account details and manage the passkeys you sign in with
        </p>
      </div>

      <ProfileForm />
      <PasskeysSection />
    </div>
  );
}
