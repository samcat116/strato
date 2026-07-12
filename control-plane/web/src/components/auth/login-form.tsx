"use client";

import { useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import Link from "next/link";
import { Building2, KeyRound, Loader2 } from "lucide-react";
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
import { oidcProvidersApi } from "@/lib/api/oidc-providers";
import type { PublicOIDCProvider } from "@/types/api";
import { toast } from "sonner";

export function LoginForm() {
  const [username, setUsername] = useState("");
  const [isLoading, setIsLoading] = useState(false);
  const { login, isWebAuthnSupported } = useAuth();
  const router = useRouter();
  const searchParams = useSearchParams();
  const ssoFailed = searchParams.get("error") === "oidc_failed";

  // SSO discovery state: hidden → org-name input → provider buttons
  const [ssoOpen, setSsoOpen] = useState(false);
  const [ssoOrgName, setSsoOrgName] = useState("");
  const [ssoLoading, setSsoLoading] = useState(false);
  const [ssoProviders, setSsoProviders] = useState<PublicOIDCProvider[]>([]);
  const [ssoOrgId, setSsoOrgId] = useState<string | null>(null);

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

  const handleSsoLookup = async (e: React.FormEvent) => {
    e.preventDefault();

    const orgName = ssoOrgName.trim();
    if (!orgName) {
      toast.error("Please enter your organization name");
      return;
    }

    setSsoLoading(true);
    try {
      const result = await oidcProvidersApi.ssoLookup(orgName);
      if (!result.organizationID || result.providers.length === 0) {
        setSsoProviders([]);
        setSsoOrgId(null);
        toast.error(
          `No SSO providers are configured for "${orgName}". Check the organization name or contact your administrator.`
        );
        return;
      }
      setSsoOrgId(result.organizationID);
      setSsoProviders(result.providers);
      if (result.providers.length === 1) {
        // Only one way to sign in — go straight to the identity provider.
        window.location.assign(
          oidcProvidersApi.authorizeUrl(
            result.organizationID,
            result.providers[0].id
          )
        );
      }
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : "SSO lookup failed"
      );
    } finally {
      setSsoLoading(false);
    }
  };

  const handleSsoContinue = (provider: PublicOIDCProvider) => {
    if (!ssoOrgId) return;
    window.location.assign(oidcProvidersApi.authorizeUrl(ssoOrgId, provider.id));
  };

  return (
    <Card className="w-full max-w-md bg-card border-border">
      <CardHeader className="space-y-1">
        <CardTitle className="text-2xl font-bold text-foreground">
          Sign in to Strato
        </CardTitle>
        <CardDescription className="text-muted-foreground">
          Use your passkey to sign in
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-4">
        {ssoFailed && (
          <div className="p-3 bg-red-500/10 border border-red-300 rounded-md text-sm text-red-800">
            Single sign-on failed. Please try again, or contact your
            organization administrator.
          </div>
        )}

        {!isWebAuthnSupported && (
          <div className="p-3 bg-red-500/10 border border-red-300 rounded-md text-sm text-red-800">
            WebAuthn is not supported in this browser. Please use a modern
            browser with passkey support.
          </div>
        )}

        {/* Quick passkey login */}
        <Button
          type="button"
          className="w-full bg-primary hover:bg-primary/90"
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
            <span className="w-full border-t border-border" />
          </div>
          <div className="relative flex justify-center text-xs uppercase">
            <span className="bg-card px-2 text-muted-foreground">
              Or specify username
            </span>
          </div>
        </div>

        {/* Username-based login */}
        <form onSubmit={handleSubmit} className="space-y-4">
          <div className="space-y-2">
            <Label htmlFor="username" className="text-foreground">
              Username
            </Label>
            <Input
              id="username"
              type="text"
              placeholder="Enter your username"
              value={username}
              onChange={(e) => setUsername(e.target.value)}
              className="bg-background border-border text-foreground placeholder:text-muted-foreground"
              disabled={isLoading}
            />
          </div>
          <Button
            type="submit"
            variant="outline"
            className="w-full border-input text-foreground hover:bg-accent"
            disabled={isLoading || !isWebAuthnSupported}
          >
            {isLoading ? (
              <Loader2 className="h-4 w-4 mr-2 animate-spin" />
            ) : null}
            Sign in with Username
          </Button>
        </form>

        <div className="relative">
          <div className="absolute inset-0 flex items-center">
            <span className="w-full border-t border-border" />
          </div>
          <div className="relative flex justify-center text-xs uppercase">
            <span className="bg-card px-2 text-muted-foreground">
              Or use single sign-on
            </span>
          </div>
        </div>

        {/* SSO login */}
        {!ssoOpen ? (
          <Button
            type="button"
            variant="outline"
            className="w-full border-input text-foreground hover:bg-accent"
            onClick={() => setSsoOpen(true)}
            disabled={isLoading}
          >
            <Building2 className="h-4 w-4 mr-2" />
            Sign in with SSO
          </Button>
        ) : ssoProviders.length > 0 ? (
          <div className="space-y-2">
            {ssoProviders.map((provider) => (
              <Button
                key={provider.id}
                type="button"
                variant="outline"
                className="w-full border-input text-foreground hover:bg-accent"
                onClick={() => handleSsoContinue(provider)}
              >
                <Building2 className="h-4 w-4 mr-2" />
                Continue with {provider.name}
              </Button>
            ))}
            <Button
              type="button"
              variant="ghost"
              className="w-full text-muted-foreground"
              onClick={() => {
                setSsoProviders([]);
                setSsoOrgId(null);
              }}
            >
              Use a different organization
            </Button>
          </div>
        ) : (
          <form onSubmit={handleSsoLookup} className="space-y-4">
            <div className="space-y-2">
              <Label htmlFor="ssoOrganization" className="text-foreground">
                Organization
              </Label>
              <Input
                id="ssoOrganization"
                type="text"
                placeholder="Enter your organization name"
                value={ssoOrgName}
                onChange={(e) => setSsoOrgName(e.target.value)}
                className="bg-background border-border text-foreground placeholder:text-muted-foreground"
                disabled={ssoLoading}
                autoFocus
              />
            </div>
            <Button
              type="submit"
              variant="outline"
              className="w-full border-input text-foreground hover:bg-accent"
              disabled={ssoLoading}
            >
              {ssoLoading ? (
                <Loader2 className="h-4 w-4 mr-2 animate-spin" />
              ) : (
                <Building2 className="h-4 w-4 mr-2" />
              )}
              Continue
            </Button>
          </form>
        )}
      </CardContent>
      <CardFooter className="flex justify-center">
        <p className="text-sm text-muted-foreground">
          Don&apos;t have an account?{" "}
          <Link href="/register" className="text-blue-600 hover:text-blue-700">
            Create one
          </Link>
        </p>
      </CardFooter>
    </Card>
  );
}
