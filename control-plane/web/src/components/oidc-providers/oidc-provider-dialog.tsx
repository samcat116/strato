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
  useCreateOIDCProvider,
  useUpdateOIDCProvider,
  oidcProviderErrorMessage,
} from "@/lib/hooks/use-oidc-providers";
import { toast } from "sonner";
import type { OIDCProvider, UpdateOIDCProviderRequest } from "@/types/api";

interface OIDCProviderDialogProps {
  orgId: string;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  /** When set, the dialog edits this provider instead of creating one. */
  provider?: OIDCProvider | null;
}

const DEFAULT_SCOPES = "openid profile email";

export function OIDCProviderDialog({
  orgId,
  open,
  onOpenChange,
  provider,
}: OIDCProviderDialogProps) {
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="bg-card border-border text-foreground max-h-[85vh] overflow-y-auto">
        {/* Radix unmounts the content when closed, so the form below mounts
            fresh on every open and its useState initializers do the prefill. */}
        <ProviderForm
          key={provider?.id ?? "create"}
          orgId={orgId}
          provider={provider}
          onOpenChange={onOpenChange}
        />
      </DialogContent>
    </Dialog>
  );
}

function ProviderForm({
  orgId,
  provider,
  onOpenChange,
}: {
  orgId: string;
  provider?: OIDCProvider | null;
  onOpenChange: (open: boolean) => void;
}) {
  const isEdit = !!provider;
  const createProvider = useCreateOIDCProvider(orgId);
  const updateProvider = useUpdateOIDCProvider(orgId);
  const isPending = createProvider.isPending || updateProvider.isPending;

  const [name, setName] = useState(provider?.name ?? "");
  const [clientID, setClientID] = useState(provider?.clientID ?? "");
  const [clientSecret, setClientSecret] = useState("");
  const [discoveryURL, setDiscoveryURL] = useState(provider?.discoveryURL ?? "");
  const [authorizationEndpoint, setAuthorizationEndpoint] = useState(
    provider?.authorizationEndpoint ?? ""
  );
  const [tokenEndpoint, setTokenEndpoint] = useState(
    provider?.tokenEndpoint ?? ""
  );
  const [userinfoEndpoint, setUserinfoEndpoint] = useState(
    provider?.userinfoEndpoint ?? ""
  );
  const [jwksURI, setJwksURI] = useState(provider?.jwksURI ?? "");
  const [endSessionEndpoint, setEndSessionEndpoint] = useState(
    provider?.endSessionEndpoint ?? ""
  );
  const [scopes, setScopes] = useState(
    provider ? provider.scopes.join(" ") : DEFAULT_SCOPES
  );

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!name.trim()) {
      toast.error("Please enter a display name for the provider");
      return;
    }
    if (!clientID.trim()) {
      toast.error("Please enter the client ID");
      return;
    }
    if (!isEdit && !clientSecret.trim()) {
      toast.error("Please enter the client secret");
      return;
    }
    if (
      !discoveryURL.trim() &&
      (!authorizationEndpoint.trim() || !tokenEndpoint.trim() || !jwksURI.trim())
    ) {
      toast.error(
        "Provide a discovery URL, or authorization endpoint, token endpoint, and JWKS URI"
      );
      return;
    }

    const scopeList = scopes.trim().split(/[\s,]+/).filter(Boolean);

    try {
      if (isEdit && provider) {
        // URL fields are always sent: the backend treats an empty string as
        // an explicit clear (omitting the field would keep the old value, so
        // e.g. a removed discovery URL would silently survive the edit).
        const data: UpdateOIDCProviderRequest = {
          name: name.trim(),
          clientID: clientID.trim(),
          discoveryURL: discoveryURL.trim(),
          authorizationEndpoint: authorizationEndpoint.trim(),
          tokenEndpoint: tokenEndpoint.trim(),
          userinfoEndpoint: userinfoEndpoint.trim(),
          jwksURI: jwksURI.trim(),
          endSessionEndpoint: endSessionEndpoint.trim(),
          scopes: scopeList.length > 0 ? scopeList : undefined,
        };
        // Blank secret means "keep the current one"
        if (clientSecret.trim()) {
          data.clientSecret = clientSecret.trim();
        }
        await updateProvider.mutateAsync({ providerId: provider.id, data });
        toast.success(`Provider "${name.trim()}" updated`);
      } else {
        await createProvider.mutateAsync({
          name: name.trim(),
          clientID: clientID.trim(),
          clientSecret: clientSecret.trim(),
          discoveryURL: discoveryURL.trim() || undefined,
          authorizationEndpoint: authorizationEndpoint.trim() || undefined,
          tokenEndpoint: tokenEndpoint.trim() || undefined,
          userinfoEndpoint: userinfoEndpoint.trim() || undefined,
          jwksURI: jwksURI.trim() || undefined,
          endSessionEndpoint: endSessionEndpoint.trim() || undefined,
          scopes: scopeList.length > 0 ? scopeList : undefined,
        });
        toast.success(`Provider "${name.trim()}" created`);
      }
      onOpenChange(false);
    } catch (error) {
      toast.error(
        oidcProviderErrorMessage(
          error,
          isEdit ? "Failed to update provider" : "Failed to create provider"
        )
      );
    }
  };

  return (
    <>
      <DialogHeader>
        <DialogTitle>
          {isEdit ? `Edit ${provider?.name}` : "Add SSO Provider"}
        </DialogTitle>
        <DialogDescription className="text-muted-foreground">
          {isEdit
            ? "Update the OpenID Connect configuration for this provider"
            : "Connect an OpenID Connect identity provider (Okta, Entra ID, Google Workspace, ...) so members can sign in with SSO"}
        </DialogDescription>
      </DialogHeader>

      <form onSubmit={handleSubmit}>
        <div className="space-y-4 py-4">
          <div className="space-y-2">
            <Label htmlFor="oidcName" className="text-foreground">
              Display Name
            </Label>
            <Input
              id="oidcName"
              placeholder="e.g. Okta"
              value={name}
              onChange={(e) => setName(e.target.value)}
              className="bg-background border-border text-foreground"
              disabled={isPending}
            />
            <p className="text-xs text-muted-foreground">
              Shown on the login screen as “Continue with{" "}
              {name.trim() || "..."}”.
            </p>
          </div>

          <div className="space-y-2">
            <Label htmlFor="oidcClientID" className="text-foreground">
              Client ID
            </Label>
            <Input
              id="oidcClientID"
              value={clientID}
              onChange={(e) => setClientID(e.target.value)}
              className="bg-background border-border text-foreground font-mono"
              disabled={isPending}
            />
          </div>

          <div className="space-y-2">
            <Label htmlFor="oidcClientSecret" className="text-foreground">
              Client Secret
            </Label>
            <Input
              id="oidcClientSecret"
              type="password"
              autoComplete="off"
              placeholder={isEdit ? "Leave blank to keep the current secret" : ""}
              value={clientSecret}
              onChange={(e) => setClientSecret(e.target.value)}
              className="bg-background border-border text-foreground font-mono"
              disabled={isPending}
            />
          </div>

          <div className="space-y-2">
            <Label htmlFor="oidcDiscoveryURL" className="text-foreground">
              Discovery URL
            </Label>
            <Input
              id="oidcDiscoveryURL"
              placeholder="https://idp.example.com/.well-known/openid-configuration"
              value={discoveryURL}
              onChange={(e) => setDiscoveryURL(e.target.value)}
              className="bg-background border-border text-foreground"
              disabled={isPending}
            />
            <p className="text-xs text-muted-foreground">
              If provided, the endpoints below are filled in automatically from
              the provider&apos;s discovery document.
            </p>
          </div>

          <div className="space-y-2">
            <Label htmlFor="oidcAuthEndpoint" className="text-foreground">
              Authorization Endpoint
            </Label>
            <Input
              id="oidcAuthEndpoint"
              placeholder="https://idp.example.com/authorize"
              value={authorizationEndpoint}
              onChange={(e) => setAuthorizationEndpoint(e.target.value)}
              className="bg-background border-border text-foreground"
              disabled={isPending}
            />
          </div>

          <div className="space-y-2">
            <Label htmlFor="oidcTokenEndpoint" className="text-foreground">
              Token Endpoint
            </Label>
            <Input
              id="oidcTokenEndpoint"
              placeholder="https://idp.example.com/token"
              value={tokenEndpoint}
              onChange={(e) => setTokenEndpoint(e.target.value)}
              className="bg-background border-border text-foreground"
              disabled={isPending}
            />
          </div>

          <div className="space-y-2">
            <Label htmlFor="oidcUserinfoEndpoint" className="text-foreground">
              Userinfo Endpoint (optional)
            </Label>
            <Input
              id="oidcUserinfoEndpoint"
              placeholder="https://idp.example.com/userinfo"
              value={userinfoEndpoint}
              onChange={(e) => setUserinfoEndpoint(e.target.value)}
              className="bg-background border-border text-foreground"
              disabled={isPending}
            />
          </div>

          <div className="space-y-2">
            <Label htmlFor="oidcJwksURI" className="text-foreground">
              JWKS URI
            </Label>
            <Input
              id="oidcJwksURI"
              placeholder="https://idp.example.com/.well-known/jwks.json"
              value={jwksURI}
              onChange={(e) => setJwksURI(e.target.value)}
              className="bg-background border-border text-foreground"
              disabled={isPending}
            />
            <p className="text-xs text-muted-foreground">
              Required to verify ID tokens; filled in automatically when a
              discovery URL is set.
            </p>
          </div>

          <div className="space-y-2">
            <Label htmlFor="oidcEndSessionEndpoint" className="text-foreground">
              End Session Endpoint (optional)
            </Label>
            <Input
              id="oidcEndSessionEndpoint"
              placeholder="https://idp.example.com/logout"
              value={endSessionEndpoint}
              onChange={(e) => setEndSessionEndpoint(e.target.value)}
              className="bg-background border-border text-foreground"
              disabled={isPending}
            />
            <p className="text-xs text-muted-foreground">
              Enables signing out of the identity provider on logout; filled in
              automatically when a discovery URL is set.
            </p>
          </div>

          <div className="space-y-2">
            <Label htmlFor="oidcScopes" className="text-foreground">
              Scopes
            </Label>
            <Input
              id="oidcScopes"
              placeholder={DEFAULT_SCOPES}
              value={scopes}
              onChange={(e) => setScopes(e.target.value)}
              className="bg-background border-border text-foreground font-mono"
              disabled={isPending}
            />
            <p className="text-xs text-muted-foreground">
              Space-separated. Defaults to {DEFAULT_SCOPES}.
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
              "Add Provider"
            )}
          </Button>
        </DialogFooter>
      </form>
    </>
  );
}
