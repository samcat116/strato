"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import { KeyRound, Loader2, CheckCircle2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Card,
  CardContent,
  CardDescription,
  CardFooter,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { useAuth } from "@/providers";
import { toast } from "sonner";

type Step = "username" | "passkey" | "complete";

export function RegisterForm() {
  const [step, setStep] = useState<Step>("username");
  const [username, setUsername] = useState("");
  const [isLoading, setIsLoading] = useState(false);
  const { register, isWebAuthnSupported } = useAuth();
  const router = useRouter();

  const handleUsernameSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (!username.trim()) {
      toast.error("Please enter a username");
      return;
    }
    setStep("passkey");
  };

  const handleCreatePasskey = async () => {
    if (!isWebAuthnSupported) {
      toast.error("WebAuthn is not supported in this browser");
      return;
    }

    setIsLoading(true);
    try {
      await register(username);
      setStep("complete");
      toast.success("Account created successfully");
      // Redirect after a short delay
      setTimeout(() => {
        router.push("/dashboard");
      }, 1500);
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : "Registration failed"
      );
    } finally {
      setIsLoading(false);
    }
  };

  return (
    <Card className="w-full max-w-md bg-gray-800 border-gray-700">
      <CardHeader className="space-y-1">
        <CardTitle className="text-2xl font-bold text-gray-100">
          Create an account
        </CardTitle>
        <CardDescription className="text-gray-400">
          {step === "username" && "Choose a username to get started"}
          {step === "passkey" && "Create a passkey for secure authentication"}
          {step === "complete" && "Your account has been created"}
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-4">
        {!isWebAuthnSupported && (
          <div className="p-3 bg-red-900/50 border border-red-700 rounded-md text-sm text-red-200">
            WebAuthn is not supported in this browser. Please use a modern
            browser with passkey support.
          </div>
        )}

        {/* Step indicators */}
        <div className="flex items-center justify-center space-x-4 mb-6">
          <div
            className={`flex items-center ${step === "username" ? "text-blue-400" : "text-gray-500"}`}
          >
            <div
              className={`w-8 h-8 rounded-full flex items-center justify-center border-2 ${
                step === "username"
                  ? "border-blue-400 bg-blue-400/10"
                  : "border-green-500 bg-green-500/10"
              }`}
            >
              {step !== "username" ? (
                <CheckCircle2 className="h-5 w-5 text-green-500" />
              ) : (
                "1"
              )}
            </div>
            <span className="ml-2 text-sm">Username</span>
          </div>
          <div className="w-8 h-px bg-gray-700" />
          <div
            className={`flex items-center ${step === "passkey" ? "text-blue-400" : step === "complete" ? "text-green-500" : "text-gray-500"}`}
          >
            <div
              className={`w-8 h-8 rounded-full flex items-center justify-center border-2 ${
                step === "passkey"
                  ? "border-blue-400 bg-blue-400/10"
                  : step === "complete"
                    ? "border-green-500 bg-green-500/10"
                    : "border-gray-600"
              }`}
            >
              {step === "complete" ? (
                <CheckCircle2 className="h-5 w-5 text-green-500" />
              ) : (
                "2"
              )}
            </div>
            <span className="ml-2 text-sm">Passkey</span>
          </div>
        </div>

        {/* Step 1: Username */}
        {step === "username" && (
          <form onSubmit={handleUsernameSubmit} className="space-y-4">
            <div className="space-y-2">
              <Label htmlFor="username" className="text-gray-200">
                Username
              </Label>
              <Input
                id="username"
                type="text"
                placeholder="Choose a username"
                value={username}
                onChange={(e) => setUsername(e.target.value)}
                className="bg-gray-900 border-gray-700 text-gray-100 placeholder:text-gray-500"
                autoFocus
              />
            </div>
            <Button
              type="submit"
              className="w-full bg-blue-600 hover:bg-blue-700"
              disabled={!username.trim()}
            >
              Continue
            </Button>
          </form>
        )}

        {/* Step 2: Create Passkey */}
        {step === "passkey" && (
          <div className="space-y-4">
            <div className="p-4 bg-gray-900 rounded-lg border border-gray-700">
              <p className="text-sm text-gray-300 mb-2">
                You&apos;re registering as:
              </p>
              <p className="text-lg font-semibold text-gray-100">{username}</p>
            </div>
            <p className="text-sm text-gray-400">
              Click the button below to create a passkey. You&apos;ll be prompted to
              use your device&apos;s biometric authentication (Face ID, Touch ID,
              Windows Hello) or a security key.
            </p>
            <Button
              type="button"
              className="w-full bg-blue-600 hover:bg-blue-700"
              onClick={handleCreatePasskey}
              disabled={isLoading || !isWebAuthnSupported}
            >
              {isLoading ? (
                <Loader2 className="h-4 w-4 mr-2 animate-spin" />
              ) : (
                <KeyRound className="h-4 w-4 mr-2" />
              )}
              Create Passkey
            </Button>
            <Button
              type="button"
              variant="ghost"
              className="w-full text-gray-400 hover:text-gray-200"
              onClick={() => setStep("username")}
              disabled={isLoading}
            >
              Back
            </Button>
          </div>
        )}

        {/* Step 3: Complete */}
        {step === "complete" && (
          <div className="text-center space-y-4">
            <div className="flex justify-center">
              <CheckCircle2 className="h-16 w-16 text-green-500" />
            </div>
            <p className="text-gray-300">
              Welcome to Strato, <strong>{username}</strong>!
            </p>
            <p className="text-sm text-gray-400">Redirecting to dashboard...</p>
          </div>
        )}
      </CardContent>
      {step === "username" && (
        <CardFooter className="flex justify-center">
          <p className="text-sm text-gray-400">
            Already have an account?{" "}
            <Link href="/login" className="text-blue-400 hover:text-blue-300">
              Sign in
            </Link>
          </p>
        </CardFooter>
      )}
    </Card>
  );
}
