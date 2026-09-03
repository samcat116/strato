import type { PropsWithChildren, ReactNode } from "react";
import Link from "next/link";
import { ArrowLeft } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";

interface DetailNavigation {
  backHref: string;
  backLabel: string;
}

export function DetailPageShell({ children }: PropsWithChildren) {
  return <div className="max-w-4xl mx-auto space-y-6">{children}</div>;
}

export function DetailGrid({ children }: PropsWithChildren) {
  return <div className="grid grid-cols-1 md:grid-cols-4 gap-4">{children}</div>;
}

export function StatCard({
  title,
  icon,
  children,
}: PropsWithChildren<{ title: ReactNode; icon: ReactNode }>) {
  return (
    <Card className="bg-card border-border">
      <CardHeader className="pb-2">
        <CardTitle className="text-sm font-medium text-muted-foreground flex items-center gap-2">
          {icon}
          {title}
        </CardTitle>
      </CardHeader>
      <CardContent>{children}</CardContent>
    </Card>
  );
}

export function DetailPageMissing({
  message,
  backHref,
  backLabel,
}: DetailNavigation & { message: string }) {
  return (
    <div className="max-w-4xl mx-auto">
      <div className="text-center py-12">
        <p className="text-muted-foreground mb-4">{message}</p>
        <Button asChild variant="outline" className="border-input">
          <Link href={backHref}>
            <ArrowLeft className="h-4 w-4 mr-2" />
            {backLabel}
          </Link>
        </Button>
      </div>
    </div>
  );
}

export function DetailPageLoading() {
  return (
    <DetailPageShell>
      <Skeleton className="h-8 w-48 bg-muted" />
      <Skeleton className="h-64 w-full bg-muted" />
    </DetailPageShell>
  );
}

export function DetailPageHeader({
  backHref,
  backLabel,
  title,
  badge,
  description,
  descriptionClassName = "text-muted-foreground mt-1",
  actions,
}: DetailNavigation & {
  title: ReactNode;
  badge?: ReactNode;
  description?: ReactNode;
  descriptionClassName?: string;
  actions?: ReactNode;
}) {
  return (
    <div className="flex items-start justify-between">
      <div>
        <Link
          href={backHref}
          className="text-sm text-muted-foreground hover:text-foreground flex items-center mb-2"
        >
          <ArrowLeft className="h-4 w-4 mr-1" />
          {backLabel}
        </Link>
        <div className="flex items-center gap-3">
          <h2 className="text-2xl font-semibold text-foreground">{title}</h2>
          {badge}
        </div>
        {description != null && <div className={descriptionClassName}>{description}</div>}
      </div>
      {actions}
    </div>
  );
}
