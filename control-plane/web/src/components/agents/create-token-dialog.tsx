"use client";

import { useState } from "react";
import { Loader2, Copy, Check } from "lucide-react";
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
import { agentsApi } from "@/lib/api/agents";
import { toast } from "sonner";
import type { AgentRegistrationToken } from "@/types/api";

interface CreateTokenDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onCreated?: () => void;
}

export function CreateTokenDialog({
  open,
  onOpenChange,
  onCreated,
}: CreateTokenDialogProps) {
  const [isLoading, setIsLoading] = useState(false);
  const [agentName, setAgentName] = useState("");
  const [expirationHours, setExpirationHours] = useState("24");
  const [createdToken, setCreatedToken] = useState<AgentRegistrationToken | null>(null);
  const [copied, setCopied] = useState(false);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!agentName.trim()) {
      toast.error("Please enter an agent name");
      return;
    }

    setIsLoading(true);
    try {
      const token = await agentsApi.createToken({
        agentName,
        expirationHours: parseInt(expirationHours) || 24,
      });
      setCreatedToken(token);
      onCreated?.();
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : "Failed to create token"
      );
    } finally {
      setIsLoading(false);
    }
  };

  const handleCopy = async () => {
    if (createdToken) {
      await navigator.clipboard.writeText(createdToken.token);
      setCopied(true);
      toast.success("Token copied to clipboard");
      setTimeout(() => setCopied(false), 2000);
    }
  };

  const handleClose = () => {
    onOpenChange(false);
    // Reset state after close animation
    setTimeout(() => {
      setAgentName("");
      setExpirationHours("24");
      setCreatedToken(null);
      setCopied(false);
    }, 200);
  };

  return (
    <Dialog open={open} onOpenChange={handleClose}>
      <DialogContent className="bg-gray-800 border-gray-700 text-gray-100">
        <DialogHeader>
          <DialogTitle>
            {createdToken ? "Registration Token Created" : "Add Compute Agent"}
          </DialogTitle>
          <DialogDescription className="text-gray-400">
            {createdToken
              ? "Use this token to register your agent"
              : "Create a registration token for a new compute agent"}
          </DialogDescription>
        </DialogHeader>

        {createdToken ? (
          <div className="space-y-4 py-4">
            <div className="p-4 bg-gray-900 rounded-lg border border-gray-700">
              <Label className="text-gray-400 text-sm">Registration Token</Label>
              <div className="flex items-center gap-2 mt-2">
                <code className="flex-1 p-2 bg-gray-950 rounded text-sm text-green-400 font-mono overflow-x-auto">
                  {createdToken.token}
                </code>
                <Button
                  size="sm"
                  variant="outline"
                  className="border-gray-600"
                  onClick={handleCopy}
                >
                  {copied ? (
                    <Check className="h-4 w-4 text-green-400" />
                  ) : (
                    <Copy className="h-4 w-4" />
                  )}
                </Button>
              </div>
            </div>

            <div className="p-4 bg-blue-900/20 rounded-lg border border-blue-700/30">
              <p className="text-sm text-blue-200">
                <strong>Important:</strong> Save this token now. It will not be
                shown again.
              </p>
              <p className="text-sm text-gray-400 mt-2">
                Expires: {new Date(createdToken.expiresAt).toLocaleString()}
              </p>
            </div>

            <div className="space-y-2">
              <Label className="text-gray-400 text-sm">
                Run this command on your agent host:
              </Label>
              <code className="block p-3 bg-gray-950 rounded text-sm text-gray-300 font-mono overflow-x-auto">
                strato-agent --token {createdToken.token}
              </code>
            </div>
          </div>
        ) : (
          <form onSubmit={handleSubmit}>
            <div className="space-y-4 py-4">
              <div className="space-y-2">
                <Label htmlFor="agentName" className="text-gray-200">
                  Agent Name
                </Label>
                <Input
                  id="agentName"
                  placeholder="my-hypervisor-01"
                  value={agentName}
                  onChange={(e) => setAgentName(e.target.value)}
                  className="bg-gray-900 border-gray-700 text-gray-100"
                  disabled={isLoading}
                />
              </div>
              <div className="space-y-2">
                <Label htmlFor="expiration" className="text-gray-200">
                  Token Expiration (hours)
                </Label>
                <Input
                  id="expiration"
                  type="number"
                  min="1"
                  max="720"
                  value={expirationHours}
                  onChange={(e) => setExpirationHours(e.target.value)}
                  className="bg-gray-900 border-gray-700 text-gray-100"
                  disabled={isLoading}
                />
              </div>
            </div>
            <DialogFooter>
              <Button
                type="button"
                variant="outline"
                onClick={handleClose}
                className="border-gray-600 text-gray-300 hover:bg-gray-700"
                disabled={isLoading}
              >
                Cancel
              </Button>
              <Button
                type="submit"
                className="bg-blue-600 hover:bg-blue-700"
                disabled={isLoading}
              >
                {isLoading ? (
                  <>
                    <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                    Creating...
                  </>
                ) : (
                  "Create Token"
                )}
              </Button>
            </DialogFooter>
          </form>
        )}

        {createdToken && (
          <DialogFooter>
            <Button
              onClick={handleClose}
              className="bg-blue-600 hover:bg-blue-700"
            >
              Done
            </Button>
          </DialogFooter>
        )}
      </DialogContent>
    </Dialog>
  );
}
