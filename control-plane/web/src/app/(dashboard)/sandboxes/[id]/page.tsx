import SandboxDetailPage from "../detail/page";

export default async function SandboxRoute({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  return <SandboxDetailPage id={id} />;
}
