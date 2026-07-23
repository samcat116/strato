"use client";

import { useState, useEffect } from "react";
import { useSearchParams } from "next/navigation";
import { useQuery } from "@tanstack/react-query";
import { Loader2, Save, Plus } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { CopyButton } from "@/components/ui/copy-button";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { Skeleton } from "@/components/ui/skeleton";
import { organizationsApi } from "@/lib/api/organizations";
import { useOrganizationMembers, usePermissions } from "@/lib/hooks";
import { MembersTable, AddMemberDialog } from "@/components/organization-members";
import { GroupsSection } from "@/components/organization-groups";
import { RolesSection, PoliciesSection } from "@/components/iam";
import { FoldersSection } from "@/components/folders";
import { SCIMTokensSection } from "@/components/scim-tokens";
import { OIDCProvidersSection } from "@/components/oidc-providers";
import { SSFStreamsSection } from "@/components/ssf-streams";
import { useAuth, useOrganization } from "@/providers";
import { toast } from "sonner";

export default function OrganizationSettingsPage() {
  const searchParams = useSearchParams();
  const idParam = searchParams.get("id");
  const { currentOrg } = useOrganization();
  const { user } = useAuth();

  // Use URL param if provided, otherwise use current org
  const id = idParam || currentOrg?.id || "";

  const [isLoading, setIsLoading] = useState(false);
  const [addMemberOpen, setAddMemberOpen] = useState(false);
  const [formData, setFormData] = useState({
    name: "",
    description: "",
  });

  const {
    data: org,
    isLoading: isOrgLoading,
    refetch,
  } = useQuery({
    queryKey: ["organization", id],
    queryFn: () => organizationsApi.get(id),
    enabled: !!id,
  });

  const { data: members = [], isLoading: isMembersLoading } =
    useOrganizationMembers(id);

  // Permission-driven gating (IAM can-i checks) rather than a hardcoded role string.
  const { permissions } = usePermissions(
    id
      ? [
          {
            key: "manage_members",
            resourceType: "organization",
            resourceId: id,
            permission: "manage_members",
          },
        ]
      : []
  );
  const canManageMembers = permissions.manage_members;

  // Set form data when org loads
  useEffect(() => {
    if (org) {
      setFormData({
        name: org.name,
        description: org.description || "",
      });
    }
  }, [org]);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!formData.name.trim()) {
      toast.error("Organization name is required");
      return;
    }

    setIsLoading(true);
    try {
      await organizationsApi.update(id, {
        name: formData.name,
        description: formData.description || undefined,
      });
      toast.success("Organization updated successfully");
      refetch();
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : "Failed to update organization"
      );
    } finally {
      setIsLoading(false);
    }
  };

  if (!id) {
    return (
      <div className="max-w-4xl mx-auto">
        <div className="text-center py-12">
          <p className="text-muted-foreground">No organization selected</p>
        </div>
      </div>
    );
  }

  if (isOrgLoading) {
    return (
      <div className="max-w-4xl mx-auto space-y-6">
        <Skeleton className="h-8 w-64 bg-muted" />
        <Skeleton className="h-64 w-full bg-muted" />
      </div>
    );
  }

  return (
    <div className="max-w-4xl mx-auto space-y-6">
      {/* Header */}
      <div>
        <h2 className="text-2xl font-semibold text-foreground">
          Organization Settings
        </h2>
        <p className="text-muted-foreground">Manage your organization configuration</p>
      </div>

      {/* Tabs */}
      <Tabs defaultValue="general" className="space-y-6">
        <TabsList className="bg-card border-border">
          <TabsTrigger
            value="general"
            className="data-[state=active]:bg-muted"
          >
            General
          </TabsTrigger>
          <TabsTrigger
            value="members"
            className="data-[state=active]:bg-muted"
          >
            Members
          </TabsTrigger>
          <TabsTrigger
            value="groups"
            className="data-[state=active]:bg-muted"
          >
            Groups
          </TabsTrigger>
          <TabsTrigger
            value="roles"
            className="data-[state=active]:bg-muted"
          >
            Roles
          </TabsTrigger>
          <TabsTrigger
            value="policies"
            className="data-[state=active]:bg-muted"
          >
            Policies
          </TabsTrigger>
          <TabsTrigger
            value="folders"
            className="data-[state=active]:bg-muted"
          >
            Folders
          </TabsTrigger>
          <TabsTrigger value="auth" className="data-[state=active]:bg-muted">
            Authentication
          </TabsTrigger>
        </TabsList>

        {/* General Tab */}
        <TabsContent value="general">
          <Card className="bg-card border-border">
            <CardHeader>
              <CardTitle className="text-lg font-semibold text-foreground">
                Organization Information
              </CardTitle>
            </CardHeader>
            <CardContent>
              <form onSubmit={handleSubmit} className="space-y-4">
                <div className="space-y-2">
                  <Label htmlFor="name" className="text-foreground">
                    Organization Name
                  </Label>
                  <Input
                    id="name"
                    value={formData.name}
                    onChange={(e) =>
                      setFormData({ ...formData, name: e.target.value })
                    }
                    className="bg-background border-border text-foreground"
                    disabled={isLoading}
                  />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="description" className="text-foreground">
                    Description
                  </Label>
                  <Input
                    id="description"
                    value={formData.description}
                    onChange={(e) =>
                      setFormData({ ...formData, description: e.target.value })
                    }
                    className="bg-background border-border text-foreground"
                    placeholder="A brief description of your organization"
                    disabled={isLoading}
                  />
                </div>
                <div className="space-y-2">
                  <Label className="text-foreground">Organization ID</Label>
                  <div className="flex items-center gap-2">
                    <Input
                      value={id}
                      className="bg-muted/50 font-mono text-muted-foreground"
                      disabled
                    />
                    <CopyButton
                      value={id}
                      label="Copy organization ID"
                      toastMessage="Organization ID copied to clipboard"
                      variant="outline"
                    />
                  </div>
                </div>
                <Button
                  type="submit"
                  className="bg-primary hover:bg-primary/90"
                  disabled={isLoading}
                >
                  {isLoading ? (
                    <>
                      <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                      Saving...
                    </>
                  ) : (
                    <>
                      <Save className="h-4 w-4 mr-2" />
                      Save Changes
                    </>
                  )}
                </Button>
              </form>
            </CardContent>
          </Card>
        </TabsContent>

        {/* Members Tab */}
        <TabsContent value="members">
          <Card className="bg-card border-border">
            <CardHeader className="flex flex-row items-center justify-between space-y-0">
              <CardTitle className="text-lg font-semibold text-foreground">
                Organization Members
              </CardTitle>
              {canManageMembers && (
                <Button
                  size="sm"
                  className="bg-primary hover:bg-primary/90"
                  onClick={() => setAddMemberOpen(true)}
                >
                  <Plus className="h-4 w-4 mr-2" />
                  Add Member
                </Button>
              )}
            </CardHeader>
            <CardContent>
              {!canManageMembers && (
                <p className="text-sm text-muted-foreground mb-4">
                  You need admin rights to add, remove, or change the roles of
                  members.
                </p>
              )}
              <MembersTable
                orgId={id}
                members={members}
                isLoading={isMembersLoading}
                canManage={canManageMembers}
                currentUserId={user?.id}
              />
            </CardContent>
          </Card>
        </TabsContent>

        {/* Groups Tab */}
        <TabsContent value="groups">
          <GroupsSection orgId={id} canManage={canManageMembers} />
        </TabsContent>

        {/* Roles Tab */}
        <TabsContent value="roles">
          <RolesSection
            ownerType="organization"
            ownerId={id}
            canManage={canManageMembers}
          />
        </TabsContent>

        {/* Policies Tab */}
        <TabsContent value="policies">
          <PoliciesSection
            ownerType="organization"
            ownerId={id}
            canManage={canManageMembers}
          />
        </TabsContent>

        {/* Folders Tab */}
        <TabsContent value="folders">
          <FoldersSection orgId={id} canManage={canManageMembers} />
        </TabsContent>

        {/* Authentication Tab */}
        <TabsContent value="auth" className="space-y-6">
          <OIDCProvidersSection orgId={id} canManage={canManageMembers} />

          <SCIMTokensSection orgId={id} canManage={canManageMembers} />

          <SSFStreamsSection orgId={id} canManage={canManageMembers} />
        </TabsContent>
      </Tabs>

      {canManageMembers && (
        <AddMemberDialog
          orgId={id}
          open={addMemberOpen}
          onOpenChange={setAddMemberOpen}
        />
      )}
    </div>
  );
}
