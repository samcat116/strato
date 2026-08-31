import { redirect } from "next/navigation";

export default async function LegacyVMDetail({
  searchParams,
}: {
  searchParams: Promise<{ id?: string }>;
}) {
  const { id } = await searchParams;
  redirect(id ? `/vms/${encodeURIComponent(id)}` : "/vms");
}
