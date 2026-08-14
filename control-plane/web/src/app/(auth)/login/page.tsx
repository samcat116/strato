"use client";

import { useEffect } from "react";
import { useRouter } from "next/navigation";
import { LoginForm } from "@/components/auth";
import { Button } from "@/components/ui/button";
import { useAuth } from "@/providers";

export default function LoginPage() {
  const { isAuthenticated, isLoading, sessionError, refresh } = useAuth();
  const router = useRouter();

  useEffect(() => {
    if (!isLoading && isAuthenticated) {
      router.replace("/dashboard");
    }
  }, [isAuthenticated, isLoading, router]);

  if (isLoading) {
    return (
      <div className="min-h-screen flex items-center justify-center">
        <div className="text-muted-foreground">Loading...</div>
      </div>
    );
  }

  if (sessionError) {
    return (
      <div className="min-h-screen flex flex-col items-center justify-center gap-4 p-6 text-center">
        <div>
          <h1 className="text-xl font-semibold">Unable to reach the control plane</h1>
          <p className="mt-2 text-sm text-muted-foreground">
            Session status could not be checked. Retry when the service is available.
          </p>
        </div>
        <Button onClick={() => void refresh()}>Try again</Button>
      </div>
    );
  }

  return (
    <div className="min-h-screen flex items-center justify-center p-4">
      <LoginForm />
    </div>
  );
}
