import { redirect } from "next/navigation";

export default async function LegacyImageDetail({
  searchParams,
}: {
  searchParams: Promise<{ id?: string; projectId?: string }>;
}) {
  const { id, projectId } = await searchParams;
  redirect(
    id && projectId
      ? `/images/${encodeURIComponent(projectId)}/${encodeURIComponent(id)}`
      : "/images"
  );
}
