import { NextResponse } from "next/server";
import type { NextRequest } from "next/server";

const controlPlanePrefixes = [
  "/api",
  "/auth",
  "/agent",
  "/health",
  "/organizations",
  "/ssf",
];

function isControlPlanePath(pathname: string): boolean {
  return controlPlanePrefixes.some(
    (prefix) => pathname === prefix || pathname.startsWith(`${prefix}/`)
  );
}

// Emit HSTS at runtime, per request. Whether the browser-facing connection is
// HTTPS is not something next.config's headers() can know — it's baked at build
// time — and TLS is terminated by a proxy/ingress in front of this service, so
// the request's own scheme is always http here. Instead we read the forwarded
// proto that the terminating layer sets: the compose nginx proxy and a
// Kubernetes TLS ingress both send X-Forwarded-Proto, so this covers every
// deployment. Plaintext requests (no proxy, e.g. localhost) carry no https
// forwarded proto and are correctly left unpinned.
export function middleware(request: NextRequest) {
  // Ingress and Gateway API route these prefixes directly to Vapor. When the
  // frontend service is reached directly (for example via the Helm NOTES
  // port-forward), proxy them here to keep the browser on one origin.
  const apiUrl = process.env.STRATO_API_URL;
  const response =
    apiUrl && isControlPlanePath(request.nextUrl.pathname)
      ? NextResponse.rewrite(
          new URL(
            `${request.nextUrl.pathname}${request.nextUrl.search}`,
            apiUrl
          )
        )
      : NextResponse.next();
  if (request.headers.get("x-forwarded-proto") === "https") {
    response.headers.set(
      "Strict-Transport-Security",
      "max-age=31536000; includeSubDomains",
    );
  }
  return response;
}

export const config = {
  // Run on everything except Next's build assets and the favicon.
  matcher: ["/((?!_next/static|_next/image|favicon.ico).*)"],
};
