import VMDetailPage from "../detail/page";

export default async function VMRoute({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  return <VMDetailPage id={id} />;
}
