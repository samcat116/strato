import AgentDetailPage from "../detail/page";

export default async function AgentPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  return <AgentDetailPage agentId={id} />;
}
