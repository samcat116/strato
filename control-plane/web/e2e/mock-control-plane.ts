import { createServer } from "node:http";

const port = Number(process.env.E2E_MOCK_PORT ?? 18_080);

const server = createServer((request, response) => {
  const pathname = new URL(request.url ?? "/", `http://${request.headers.host}`).pathname;
  response.setHeader("content-type", "application/json");

  // Browser integration fixtures opt in per isolated context. The default
  // stays unauthenticated for the login/deep-link tests.
  const fixtureSession = request.headers.cookie?.includes("strato-e2e=terminal");
  if (fixtureSession && pathname === "/auth/session") {
    response.writeHead(200).end(JSON.stringify({ user: { id: "e2e-user", username: "terminal-test", currentOrganizationId: "e2e-org" } }));
    return;
  }
  if (fixtureSession && pathname === "/api/organizations") {
    response.writeHead(200).end(JSON.stringify([{ id: "e2e-org", name: "Terminal tests" }]));
    return;
  }
  if (fixtureSession && pathname === "/api/organizations/e2e-org/projects") {
    response.writeHead(200).end("[]");
    return;
  }

  if (pathname === "/auth/session") {
    response.writeHead(401).end(JSON.stringify({ reason: "Not authenticated" }));
    return;
  }

  if (pathname === "/api/public/registration") {
    response.writeHead(200).end(JSON.stringify({ selfRegistrationEnabled: false }));
    return;
  }

  response
    .writeHead(404)
    .end(JSON.stringify({ reason: `Unhandled test endpoint: ${pathname}` }));
});

server.listen(port, "127.0.0.1", () => {
  console.log(`Mock control plane listening on http://127.0.0.1:${port}`);
});
