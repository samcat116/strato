"use client";

import { useState, useEffect } from "react";
import { useSearchParams } from "next/navigation";
import { useQuery } from "@tanstack/react-query";
import { Loader2, Save, Plus } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { Skeleton } from "@/components/ui/skeleton";
import { organizationsApi } from "@/lib/api/organizations";
import { useOrganizationMembers } from "@/lib/hooks";
import { MembersTable, AddMemberDialog } from "@/components/organization-members";
import { GroupsSection } from "@/components/organization-groups";
import { OrganizationalUnitsSection } from "@/components/organizational-units";
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

  const canManageMembers = org?.userRole === "admin";

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
          <p className="text-gray-400">No organization selected</p>
        </div>
      </div>
    );
  }

  if (isOrgLoading) {
    return (
      <div className="max-w-4xl mx-auto space-y-6">
        <Skeleton className="h-8 w-64 bg-gray-700" />
        <Skeleton className="h-64 w-full bg-gray-700" />
      </div>
    );
  }

  return (
    <div className="max-w-4xl mx-auto space-y-6">
      {/* Header */}
      <div>
        <h2 className="text-2xl font-semibold text-gray-100">
          Organization Settings
        </h2>
        <p className="text-gray-400">Manage your organization configuration</p>
      </div>

      {/* Tabs */}
      <Tabs defaultValue="general" className="space-y-6">
        <TabsList className="bg-gray-800 border-gray-700">
          <TabsTrigger
            value="general"
            className="data-[state=active]:bg-gray-700"
          >
            General
          </TabsTrigger>
          <TabsTrigger
            value="members"
            className="data-[state=active]:bg-gray-700"
          >
            Members
          </TabsTrigger>
          <TabsTrigger
            value="groups"
            className="data-[state=active]:bg-gray-700"
          >
            Groups
          </TabsTrigger>
          <TabsTrigger
            value="organizational-units"
            className="data-[state=active]:bg-gray-700"
          >
            Organizational Units
          </TabsTrigger>
          <TabsTrigger value="auth" className="data-[state=active]:bg-gray-700">
            Authentication
          </TabsTrigger>
        </TabsList>

        {/* General Tab */}
        <TabsContent value="general">
          <Card className="bg-gray-800 border-gray-700">
            <CardHeader>
              <CardTitle className="text-lg font-semibold text-gray-100">
                Organization Information
              </CardTitle>
            </CardHeader>
            <CardContent>
              <form onSubmit={handleSubmit} className="space-y-4">
                <div className="space-y-2">
                  <Label htmlFor="name" className="text-gray-200">
                    Organization Name
                  </Label>
                  <Input
                    id="name"
                    value={formData.name}
                    onChange={(e) =>
                      setFormData({ ...formData, name: e.target.value })
                    }
                    className="bg-gray-900 border-gray-700 text-gray-100"
                    disabled={isLoading}
                  />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="description" className="text-gray-200">
                    Description
                  </Label>
                  <Input
                    id="description"
                    value={formData.description}
                    onChange={(e) =>
                      setFormData({ ...formData, description: e.target.value })
                    }
                    className="bg-gray-900 border-gray-700 text-gray-100"
                    placeholder="A brief description of your organization"
                    disabled={isLoading}
                  />
                </div>
                <div className="space-y-2">
                  <Label className="text-gray-200">Organization ID</Label>
                  <Input
                    value={id}
                    className="bg-gray-950 border-gray-700 text-gray-400 font-mono"
                    disabled
                  />
                </div>
                <Button
                  type="submit"
                  className="bg-blue-600 hover:bg-blue-700"
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
          <Card className="bg-gray-800 border-gray-700">
            <CardHeader className="flex flex-row items-center justify-between space-y-0">
              <CardTitle className="text-lg font-semibold text-gray-100">
                Organization Members
              </CardTitle>
              {canManageMembers && (
                <Button
                  size="sm"
                  className="bg-blue-600 hover:bg-blue-700"
                  onClick={() => setAddMemberOpen(true)}
                >
                  <Plus className="h-4 w-4 mr-2" />
                  Add Member
                </Button>
              )}
            </CardHeader>
            <CardContent>
              {!canManageMembers && (
                <p className="text-sm text-gray-400 mb-4">
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

        {/* Organizational Units Tab */}
        <TabsContent value="organizational-units">
          <OrganizationalUnitsSection orgId={id} canManage={canManageMembers} />
        </TabsContent>

        {/* Authentication Tab */}
        <TabsContent value="auth">
          <Card className="bg-gray-800 border-gray-700">
            <CardHeader>
              <CardTitle className="text-lg font-semibold text-gray-100">
                OIDC Configuration
              </CardTitle>
            </CardHeader>
            <CardContent>
              <p className="text-gray-400">
                OIDC provider configuration coming soon. Configure SSO providers
                for your organization.
              </p>
            </CardContent>
          </Card>
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
