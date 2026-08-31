import { redirect } from "next/navigation";

export default async function LegacySandboxDetail({
  searchParams,
}: {
  searchParams: Promise<{ id?: string }>;
}) {
  const { id } = await searchParams;
  redirect(id ? `/sandboxes/${encodeURIComponent(id)}` : "/sandboxes");
}
