import ImageDetailPage from "../../detail/page";

export default async function ImagePage({
  params,
}: {
  params: Promise<{ projectId: string; id: string }>;
}) {
  const { projectId, id } = await params;
  return <ImageDetailPage projectId={projectId} imageId={id} />;
}
