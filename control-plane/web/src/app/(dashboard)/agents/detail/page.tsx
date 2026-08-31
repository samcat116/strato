import { redirect } from "next/navigation";

export default async function LegacyAgentDetail({
  searchParams,
}: {
  searchParams: Promise<{ id?: string }>;
}) {
  const { id } = await searchParams;
  redirect(id ? `/agents/${encodeURIComponent(id)}` : "/agents");
}
