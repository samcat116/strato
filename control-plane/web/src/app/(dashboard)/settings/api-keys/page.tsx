"use client";

import { useState } from "react";
import { Plus } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { APIKeyTable, CreateAPIKeyDialog } from "@/components/api-keys";
import { useAPIKeys } from "@/lib/hooks";

export default function APIKeysPage() {
  const [createOpen, setCreateOpen] = useState(false);
  const { data: apiKeys = [], isLoading } = useAPIKeys();

  return (
    <div className="max-w-7xl mx-auto space-y-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-2xl font-semibold text-gray-100">API Keys</h2>
          <p className="text-gray-400">
            Manage API keys for programmatic access to the Strato API
          </p>
        </div>
        <Button
          className="bg-blue-600 hover:bg-blue-700"
          onClick={() => setCreateOpen(true)}
        >
          <Plus className="h-4 w-4 mr-2" />
          Create API Key
        </Button>
      </div>

      {/* Key List */}
      <Card className="bg-gray-800 border-gray-700">
        <CardHeader>
          <CardTitle className="text-lg font-semibold text-gray-100">
            Your API Keys
          </CardTitle>
        </CardHeader>
        <CardContent>
          <APIKeyTable apiKeys={apiKeys} isLoading={isLoading} />
        </CardContent>
      </Card>

      {/* Create Dialog */}
      <CreateAPIKeyDialog open={createOpen} onOpenChange={setCreateOpen} />
    </div>
  );
}
