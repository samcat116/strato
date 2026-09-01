import Link from "next/link";
import { FolderPlus } from "lucide-react";
import { Button } from "@/components/ui/button";

export function ProjectRequiredState({ resource }: { resource: string }) {
  return (
    <div className="flex flex-col items-center py-12 text-center">
      <FolderPlus className="mb-4 h-10 w-10 text-muted-foreground" />
      <h3 className="font-medium text-foreground">Select a project first</h3>
      <p className="mt-1 max-w-md text-sm text-muted-foreground">
        {resource} belong to a project. Create one or select an existing project
        from the sidebar before continuing.
      </p>
      <Button asChild variant="outline" className="mt-4">
        <Link href="/projects">Manage projects</Link>
      </Button>
    </div>
  );
}
