"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import { KeyRound, Loader2 } from "lucide-react";
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

export function LoginForm() {
  const [username, setUsername] = useState("");
  const [isLoading, setIsLoading] = useState(false);
  const { login, isWebAuthnSupported } = useAuth();
  const router = useRouter();

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!isWebAuthnSupported) {
      toast.error("WebAuthn is not supported in this browser");
      return;
    }

    setIsLoading(true);
    try {
      await login(username || null);
      toast.success("Login successful");
      router.push("/dashboard");
    } catch (error) {
      toast.error(error instanceof Error ? error.message : "Login failed");
    } finally {
      setIsLoading(false);
    }
  };

  const handlePasskeyLogin = async () => {
    if (!isWebAuthnSupported) {
      toast.error("WebAuthn is not supported in this browser");
      return;
    }

    setIsLoading(true);
    try {
      await login(null); // Discoverable credentials - no username needed
      toast.success("Login successful");
      router.push("/dashboard");
    } catch (error) {
      toast.error(error instanceof Error ? error.message : "Login failed");
    } finally {
      setIsLoading(false);
    }
  };

  return (
    <Card className="w-full max-w-md bg-gray-800 border-gray-700">
      <CardHeader className="space-y-1">
        <CardTitle className="text-2xl font-bold text-gray-100">
          Sign in to Strato
        </CardTitle>
        <CardDescription className="text-gray-400">
          Use your passkey to sign in
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-4">
        {!isWebAuthnSupported && (
          <div className="p-3 bg-red-900/50 border border-red-700 rounded-md text-sm text-red-200">
            WebAuthn is not supported in this browser. Please use a modern
            browser with passkey support.
          </div>
        )}

        {/* Quick passkey login */}
        <Button
          type="button"
          className="w-full bg-blue-600 hover:bg-blue-700"
          onClick={handlePasskeyLogin}
          disabled={isLoading || !isWebAuthnSupported}
        >
          {isLoading ? (
            <Loader2 className="h-4 w-4 mr-2 animate-spin" />
          ) : (
            <KeyRound className="h-4 w-4 mr-2" />
          )}
          Sign in with Passkey
        </Button>

        <div className="relative">
          <div className="absolute inset-0 flex items-center">
            <span className="w-full border-t border-gray-700" />
          </div>
          <div className="relative flex justify-center text-xs uppercase">
            <span className="bg-gray-800 px-2 text-gray-500">
              Or specify username
            </span>
          </div>
        </div>

        {/* Username-based login */}
        <form onSubmit={handleSubmit} className="space-y-4">
          <div className="space-y-2">
            <Label htmlFor="username" className="text-gray-200">
              Username
            </Label>
            <Input
              id="username"
              type="text"
              placeholder="Enter your username"
              value={username}
              onChange={(e) => setUsername(e.target.value)}
              className="bg-gray-900 border-gray-700 text-gray-100 placeholder:text-gray-500"
              disabled={isLoading}
            />
          </div>
          <Button
            type="submit"
            variant="outline"
            className="w-full border-gray-600 text-gray-200 hover:bg-gray-700"
            disabled={isLoading || !isWebAuthnSupported}
          >
            {isLoading ? (
              <Loader2 className="h-4 w-4 mr-2 animate-spin" />
            ) : null}
            Sign in with Username
          </Button>
        </form>
      </CardContent>
      <CardFooter className="flex justify-center">
        <p className="text-sm text-gray-400">
          Don&apos;t have an account?{" "}
          <Link href="/register" className="text-blue-400 hover:text-blue-300">
            Create one
          </Link>
        </p>
      </CardFooter>
    </Card>
  );
}
