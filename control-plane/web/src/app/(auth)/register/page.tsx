"use client";

import { useEffect } from "react";
import { useRouter } from "next/navigation";
import { RegisterForm } from "@/components/auth";
import { useAuth } from "@/providers";
import { useRegistrationPolicy } from "@/lib/hooks";

export default function RegisterPage() {
  const { isAuthenticated, isLoading } = useAuth();
  // Hiding the login page's link isn't enough — /register is a URL anyone can
  // type. Send them to the sign-in page rather than announcing that a closed
  // registration flow exists here; the backend refuses the request regardless.
  const { data: registration, isLoading: isPolicyLoading } =
    useRegistrationPolicy();
  const router = useRouter();

  const registrationClosed =
    registration != null && !registration.selfRegistrationEnabled;

  useEffect(() => {
    if (!isLoading && isAuthenticated) {
      router.replace("/dashboard");
      return;
    }
    if (registrationClosed) {
      router.replace("/login");
    }
  }, [isAuthenticated, isLoading, registrationClosed, router]);

  // Keep the loading state up through the redirect so the form never flashes.
  if (isLoading || isPolicyLoading || registrationClosed) {
    return (
      <div className="min-h-screen flex items-center justify-center">
        <div className="text-muted-foreground">Loading...</div>
      </div>
    );
  }

  return (
    <div className="min-h-screen flex items-center justify-center p-4">
      <RegisterForm />
    </div>
  );
}
