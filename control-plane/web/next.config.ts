import { execSync } from "node:child_process";
import type { NextConfig } from "next";

// Build identity, baked into the client bundle so the UI can show which build is
// running. Mirrors the control plane's STRATO_VERSION/STRATO_GIT_SHA convention
// (see control-plane/Sources/App/BuildInfo.swift): CI and Helm inject these; a
// local `next dev` has no build args, so fall back to reading the git short hash
// directly. Inside the Docker builder there is no .git, so that fallback yields
// "" and the injected build arg is the only source — see the web Dockerfile.
function resolveGitSHA(): string {
  if (process.env.STRATO_GIT_SHA) return process.env.STRATO_GIT_SHA;
  try {
    return execSync("git rev-parse --short HEAD", {
      stdio: ["ignore", "pipe", "ignore"],
    })
      .toString()
      .trim();
  } catch {
    return "";
  }
}

const nextConfig: NextConfig = {
  output: "standalone", // Creates minimal server bundle for Docker
  poweredByHeader: false, // Don't advertise the framework in `X-Powered-By`
  images: {
    unoptimized: true,
  },

  // Inlined into the client bundle at build time (NEXT_PUBLIC_* → string
  // literals). Consumed by src/lib/version.ts / the sidebar version label.
  env: {
    NEXT_PUBLIC_APP_VERSION: process.env.STRATO_VERSION ?? "",
    NEXT_PUBLIC_GIT_SHA: resolveGitSHA(),
  },

  // Security headers for the user-facing HTML this service serves (/, /login,
  // ...). In the compose/Helm topologies these pages come from here, not the
  // control plane, so the control plane's SecurityHeadersMiddleware doesn't cover
  // them — mirror the same headers here.
  //
  // Only unconditional headers belong here: `headers()` is evaluated during
  // `next build` and baked into the routes manifest, so it can't gate on runtime
  // TLS state. HSTS, which must only be sent over HTTPS, is emitted per request
  // in middleware.ts (keyed on X-Forwarded-Proto) instead.
  //
  // Content-Security-Policy as defense-in-depth over React's escaping.
  // `script-src`/`style-src` keep `'unsafe-inline'` deliberately: Next.js ships
  // inline hydration scripts and next-themes an inline theme script, neither
  // nonce-tagged, so a nonce/`strict-dynamic` policy would block them and blank
  // the app. The value comes from restricting everything else — `default-src`
  // and `connect-src 'self'` confine fetch/XHR and the same-origin console
  // WebSocket (the API and UI share an origin in every supported topology, via
  // ingress routing or the middleware.ts rewrite); `frame-ancestors 'none'`
  // mirrors X-Frame-Options; `object-src`/`base-uri`/`form-action` close
  // plugin, base-tag, and form-hijack vectors. Tightening `script-src` to a
  // nonce is a follow-up (needs next-themes + Next nonce plumbing).
  async headers() {
    const csp = [
      "default-src 'self'",
      "base-uri 'self'",
      "object-src 'none'",
      "frame-ancestors 'none'",
      "form-action 'self'",
      "script-src 'self' 'unsafe-inline'",
      "style-src 'self' 'unsafe-inline'",
      "img-src 'self' data: blob: https:",
      "font-src 'self' data:",
      "connect-src 'self'",
    ].join("; ");
    return [
      {
        source: "/:path*",
        headers: [
          { key: "Content-Security-Policy", value: csp },
          { key: "X-Content-Type-Options", value: "nosniff" },
          { key: "X-Frame-Options", value: "DENY" },
          { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
        ],
      },
    ];
  },

  // Rewrites for local development (proxies API to Vapor backend)
  async rewrites() {
    if (process.env.NODE_ENV === "development") {
      const apiUrl = process.env.NEXT_PUBLIC_API_URL || "http://localhost:8080";
      return [
        { source: "/api/:path*", destination: `${apiUrl}/api/:path*` },
        { source: "/auth/:path*", destination: `${apiUrl}/auth/:path*` },
        { source: "/agent/:path*", destination: `${apiUrl}/agent/:path*` },
        { source: "/health/:path*", destination: `${apiUrl}/health/:path*` },
        {
          source: "/organizations/:path*",
          destination: `${apiUrl}/organizations/:path*`,
        },
      ];
    }
    return [];
  },
};

export default nextConfig;
