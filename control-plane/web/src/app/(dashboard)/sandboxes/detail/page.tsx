"use client";

import { useSearchParams } from "next/navigation";
import Link from "next/link";
import dynamic from "next/dynamic";
import {
  ArrowLeft,
  Cpu,
  MemoryStick,
  Clock,
  Timer,
  Terminal,
  ScrollText,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import {
  SandboxStatusBadge,
  SandboxActions,
  SandboxLogViewer,
  formatMemory,
} from "@/components/sandboxes";
import { useSandbox, useInvalidateSandboxes } from "@/lib/hooks";

// Dynamically import SandboxTerminal to avoid SSR issues with xterm.js
const SandboxTerminal = dynamic(
  () =>
    import("@/components/terminal/sandbox-terminal").then(
      (mod) => mod.SandboxTerminal
    ),
  {
    ssr: false,
    loading: () => (
      <div className="h-[500px] bg-background rounded-lg flex items-center justify-center">
        <p className="text-muted-foreground">Loading terminal...</p>
      </div>
    ),
  }
);

export default function SandboxDetailPage() {
  const searchParams = useSearchParams();
  const id = searchParams.get("id") || "";
  const { data: sandbox, isLoading, error } = useSandbox(id);
  const invalidateSandboxes = useInvalidateSandboxes();

  if (!id) {
    return (
      <div className="max-w-4xl mx-auto">
        <div className="text-center py-12">
          <p className="text-muted-foreground mb-4">No sandbox ID provided</p>
          <Link href="/sandboxes">
            <Button variant="outline" className="border-input">
              <ArrowLeft className="h-4 w-4 mr-2" />
              Back to Sandboxes
            </Button>
          </Link>
        </div>
      </div>
    );
  }

  if (isLoading) {
    return (
      <div className="max-w-4xl mx-auto space-y-6">
        <Skeleton className="h-8 w-48 bg-muted" />
        <Skeleton className="h-64 w-full bg-muted" />
      </div>
    );
  }

  if (error || !sandbox) {
    return (
      <div className="max-w-4xl mx-auto">
        <div className="text-center py-12">
          <p className="text-muted-foreground mb-4">
            Sandbox not found or failed to load
          </p>
          <Link href="/sandboxes">
            <Button variant="outline" className="border-input">
              <ArrowLeft className="h-4 w-4 mr-2" />
              Back to Sandboxes
            </Button>
          </Link>
        </div>
      </div>
    );
  }

  const entrypoint = sandbox.entrypoint?.join(" ");
  const cmd = sandbox.cmd?.join(" ");
  const envEntries = Object.entries(sandbox.env ?? {});
  const isRunning = sandbox.status === "Running";

  return (
    <div className="max-w-4xl mx-auto space-y-6">
      {/* Header */}
      <div className="flex items-start justify-between">
        <div>
          <Link
            href="/sandboxes"
            className="text-sm text-muted-foreground hover:text-foreground flex items-center mb-2"
          >
            <ArrowLeft className="h-4 w-4 mr-1" />
            Back to Sandboxes
          </Link>
          <div className="flex items-center gap-3">
            <h2 className="text-2xl font-semibold text-foreground">
              {sandbox.name}
            </h2>
            <SandboxStatusBadge
              status={sandbox.status}
              sandboxId={sandbox.id}
              exitCode={sandbox.exitCode}
            />
          </div>
          <p className="text-muted-foreground mt-1 font-mono text-sm">
            {sandbox.image}
          </p>
        </div>
        <SandboxActions
          sandbox={sandbox}
          onActionComplete={invalidateSandboxes}
        />
      </div>

      {/* Tabs */}
      <Tabs defaultValue="overview" className="w-full">
        <TabsList className="bg-card border-border">
          <TabsTrigger
            value="overview"
            className="data-[state=active]:bg-muted"
          >
            Overview
          </TabsTrigger>
          <TabsTrigger
            value="terminal"
            className="data-[state=active]:bg-muted"
            disabled={!isRunning}
          >
            <Terminal className="h-4 w-4 mr-2" />
            Terminal
            {!isRunning && (
              <span className="ml-2 text-xs text-muted-foreground">
                (sandbox not running)
              </span>
            )}
          </TabsTrigger>
          <TabsTrigger value="logs" className="data-[state=active]:bg-muted">
            <ScrollText className="h-4 w-4 mr-2" />
            Logs
          </TabsTrigger>
        </TabsList>

        <TabsContent value="overview" className="space-y-6 mt-6">
          {/* Resources */}
          <div className="grid grid-cols-1 md:grid-cols-4 gap-4">
            <Card className="bg-card border-border">
              <CardHeader className="pb-2">
                <CardTitle className="text-sm font-medium text-muted-foreground flex items-center gap-2">
                  <Cpu className="h-4 w-4" />
                  vCPUs
                </CardTitle>
              </CardHeader>
              <CardContent>
                <div className="text-xl font-bold text-foreground">
                  {sandbox.cpus}
                </div>
              </CardContent>
            </Card>
            <Card className="bg-card border-border">
              <CardHeader className="pb-2">
                <CardTitle className="text-sm font-medium text-muted-foreground flex items-center gap-2">
                  <MemoryStick className="h-4 w-4" />
                  Memory
                </CardTitle>
              </CardHeader>
              <CardContent>
                <div className="text-xl font-bold text-foreground">
                  {formatMemory(sandbox.memory)}
                </div>
              </CardContent>
            </Card>
            <Card className="bg-card border-border">
              <CardHeader className="pb-2">
                <CardTitle className="text-sm font-medium text-muted-foreground flex items-center gap-2">
                  <Timer className="h-4 w-4" />
                  TTL
                </CardTitle>
              </CardHeader>
              <CardContent>
                <div className="text-xl font-bold text-foreground">
                  {sandbox.ttlSeconds != null ? `${sandbox.ttlSeconds}s` : "—"}
                </div>
              </CardContent>
            </Card>
            <Card className="bg-card border-border">
              <CardHeader className="pb-2">
                <CardTitle className="text-sm font-medium text-muted-foreground flex items-center gap-2">
                  <Clock className="h-4 w-4" />
                  Created
                </CardTitle>
              </CardHeader>
              <CardContent>
                <div className="text-sm font-medium text-foreground">
                  {new Date(sandbox.createdAt).toLocaleDateString()}
                </div>
                <p className="text-sm text-muted-foreground">
                  {new Date(sandbox.createdAt).toLocaleTimeString()}
                </p>
              </CardContent>
            </Card>
          </div>

          {/* Details */}
          <Card className="bg-card border-border">
            <CardHeader>
              <CardTitle className="text-lg font-semibold text-foreground">
                Details
              </CardTitle>
            </CardHeader>
            <CardContent className="space-y-4">
              <div className="grid grid-cols-2 gap-4 text-sm">
                <div>
                  <p className="text-muted-foreground">ID</p>
                  <p className="text-foreground font-mono">{sandbox.id}</p>
                </div>
                <div>
                  <p className="text-muted-foreground">Environment</p>
                  <p className="text-foreground">{sandbox.environment}</p>
                </div>
                <div className="col-span-2">
                  <p className="text-muted-foreground">Image Digest</p>
                  <p className="text-foreground font-mono break-all">
                    {sandbox.imageDigest ?? "Not yet resolved"}
                  </p>
                </div>
                <div>
                  <p className="text-muted-foreground">Hypervisor</p>
                  {sandbox.hypervisorId ? (
                    <Link
                      href={`/agents/detail?id=${sandbox.hypervisorId}`}
                      className="text-blue-600 hover:text-blue-700 hover:underline font-mono"
                    >
                      {sandbox.hypervisorId}
                    </Link>
                  ) : (
                    <p className="text-foreground">Unassigned</p>
                  )}
                </div>
                {sandbox.exitCode != null && (
                  <div>
                    <p className="text-muted-foreground">Exit Code</p>
                    <p
                      className={
                        sandbox.exitCode === 0
                          ? "text-foreground font-mono"
                          : "text-red-600 font-mono"
                      }
                    >
                      {sandbox.exitCode}
                    </p>
                  </div>
                )}
                <div>
                  <p className="text-muted-foreground">Last Updated</p>
                  <p className="text-foreground">
                    {new Date(sandbox.updatedAt).toLocaleString()}
                  </p>
                </div>
              </div>
            </CardContent>
          </Card>

          {/* Process configuration */}
          <Card className="bg-card border-border">
            <CardHeader>
              <CardTitle className="text-lg font-semibold text-foreground">
                Process
              </CardTitle>
            </CardHeader>
            <CardContent className="space-y-4 text-sm">
              <div>
                <p className="text-muted-foreground">Entrypoint</p>
                <p className="text-foreground font-mono">
                  {entrypoint || (
                    <span className="text-muted-foreground">
                      Image default
                    </span>
                  )}
                </p>
              </div>
              <div>
                <p className="text-muted-foreground">Command</p>
                <p className="text-foreground font-mono">
                  {cmd || (
                    <span className="text-muted-foreground">
                      Image default
                    </span>
                  )}
                </p>
              </div>
              <div>
                <p className="text-muted-foreground">Working Directory</p>
                <p className="text-foreground font-mono">
                  {sandbox.workingDir || (
                    <span className="text-muted-foreground">
                      Image default
                    </span>
                  )}
                </p>
              </div>
              <div>
                <p className="text-muted-foreground mb-1">
                  Environment ({envEntries.length})
                </p>
                {envEntries.length === 0 ? (
                  <p className="text-muted-foreground">No overrides</p>
                ) : (
                  <div className="space-y-1 font-mono text-xs">
                    {envEntries.map(([key, value]) => (
                      <div key={key} className="text-foreground break-all">
                        <span className="text-blue-600">{key}</span>={value}
                      </div>
                    ))}
                  </div>
                )}
              </div>
            </CardContent>
          </Card>
        </TabsContent>

        <TabsContent value="terminal" className="mt-6">
          {isRunning ? (
            <Card className="bg-background border-border">
              <CardContent className="p-0">
                <SandboxTerminal
                  sandboxId={id}
                  className="h-[500px] rounded-lg overflow-hidden"
                />
              </CardContent>
            </Card>
          ) : (
            <Card className="bg-card border-border">
              <CardContent className="py-12 text-center">
                <Terminal className="h-12 w-12 text-muted-foreground mx-auto mb-4" />
                <p className="text-muted-foreground">
                  The terminal is only available when the sandbox is running.
                </p>
                <p className="text-muted-foreground text-sm mt-2">
                  Start the sandbox to open an exec session.
                </p>
              </CardContent>
            </Card>
          )}
        </TabsContent>

        <TabsContent value="logs" className="mt-6">
          <SandboxLogViewer sandboxId={id} />
        </TabsContent>
      </Tabs>
    </div>
  );
}
