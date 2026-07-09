"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { Building2, Loader2, CheckCircle2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { organizationsApi } from "@/lib/api/organizations";
import { useAuth, useOrganization } from "@/providers";
import { toast } from "sonner";

export default function OnboardingPage() {
  const [orgName, setOrgName] = useState("");
  const [orgDescription, setOrgDescription] = useState("");
  const [isLoading, setIsLoading] = useState(false);
  const [isComplete, setIsComplete] = useState(false);
  const { isAuthenticated, isLoading: authLoading } = useAuth();
  const { organizations, isLoading: orgsLoading, refresh } = useOrganization();
  const router = useRouter();

  // Only the first-run case belongs here: send unauthenticated visitors to
  // login, and anyone who already has an organization back to the dashboard.
  useEffect(() => {
    if (!authLoading && !isAuthenticated) {
      router.replace("/login");
      return;
    }
    // Skip while completing: the success screen handles its own redirect so
    // the "you're all set" confirmation isn't cut short.
    if (
      isAuthenticated &&
      !orgsLoading &&
      organizations.length > 0 &&
      !isComplete
    ) {
      router.replace("/dashboard");
    }
  }, [authLoading, isAuthenticated, orgsLoading, organizations, isComplete, router]);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!orgName.trim()) {
      toast.error("Please enter an organization name");
      return;
    }

    setIsLoading(true);
    try {
      await organizationsApi.create({
        name: orgName,
        description: orgDescription || undefined,
      });
      await refresh();
      setIsComplete(true);
      toast.success("Organization created successfully");
      setTimeout(() => {
        router.push("/dashboard");
      }, 1500);
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : "Failed to create organization"
      );
    } finally {
      setIsLoading(false);
    }
  };

  return (
    <div className="min-h-screen flex items-center justify-center p-4">
      <Card className="w-full max-w-md bg-card border-border">
        <CardHeader className="space-y-1">
          <CardTitle className="text-2xl font-bold text-foreground flex items-center gap-2">
            <Building2 className="h-6 w-6 text-blue-600" />
            Welcome to Strato
          </CardTitle>
          <CardDescription className="text-muted-foreground">
            {isComplete
              ? "You're all set!"
              : "Let's create your first organization to get started"}
          </CardDescription>
        </CardHeader>
        <CardContent>
          {isComplete ? (
            <div className="text-center space-y-4">
              <div className="flex justify-center">
                <CheckCircle2 className="h-16 w-16 text-green-600" />
              </div>
              <p className="text-foreground/80">
                Your organization <strong>{orgName}</strong> is ready!
              </p>
              <p className="text-sm text-muted-foreground">
                Redirecting to dashboard...
              </p>
            </div>
          ) : (
            <form onSubmit={handleSubmit} className="space-y-4">
              <div className="space-y-2">
                <Label htmlFor="orgName" className="text-foreground">
                  Organization Name
                </Label>
                <Input
                  id="orgName"
                  type="text"
                  placeholder="My Company"
                  value={orgName}
                  onChange={(e) => setOrgName(e.target.value)}
                  className="bg-background border-border text-foreground placeholder:text-muted-foreground"
                  autoFocus
                  disabled={isLoading}
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="orgDescription" className="text-foreground">
                  Description{" "}
                  <span className="text-muted-foreground">(optional)</span>
                </Label>
                <Input
                  id="orgDescription"
                  type="text"
                  placeholder="A brief description of your organization"
                  value={orgDescription}
                  onChange={(e) => setOrgDescription(e.target.value)}
                  className="bg-background border-border text-foreground placeholder:text-muted-foreground"
                  disabled={isLoading}
                />
              </div>
              <Button
                type="submit"
                className="w-full bg-primary hover:bg-primary/90"
                disabled={isLoading || !orgName.trim()}
              >
                {isLoading ? (
                  <>
                    <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                    Creating...
                  </>
                ) : (
                  "Create Organization"
                )}
              </Button>
            </form>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
