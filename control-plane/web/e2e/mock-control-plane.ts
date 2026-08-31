import { createServer } from "node:http";

const port = 18_080;

const server = createServer((request, response) => {
  const pathname = new URL(request.url ?? "/", `http://${request.headers.host}`).pathname;
  response.setHeader("content-type", "application/json");

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
