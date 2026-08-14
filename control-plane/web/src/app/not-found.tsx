import Link from "next/link";
import { Button } from "@/components/ui/button";

export default function NotFound() {
  return (
    <div className="min-h-screen flex flex-col items-center justify-center gap-4 p-6 text-center">
      <div>
        <h1 className="text-2xl font-semibold">Page not found</h1>
        <p className="mt-2 text-muted-foreground">
          The page may have moved or the resource may no longer exist.
        </p>
      </div>
      <Button asChild><Link href="/dashboard">Return to overview</Link></Button>
    </div>
  );
}
