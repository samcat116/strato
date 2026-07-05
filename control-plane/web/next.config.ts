import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  output: "standalone", // Creates minimal server bundle for Docker
  images: {
    unoptimized: true,
  },

  // Security headers for the user-facing HTML this service serves (/, /login,
  // ...). In the compose/Helm topologies these pages come from here, not the
  // control plane, so the control plane's SecurityHeadersMiddleware doesn't cover
  // them — mirror the same headers here.
  //
  // Only unconditional headers belong here: `headers()` is evaluated during
  // `next build` and baked into the routes manifest, so runtime env (e.g.
  // HTTP_TLS_ENABLED) can't influence it. HSTS is therefore emitted by the
  // TLS-terminating runtime layer instead — nginx in the compose deployment
  // (gated on the forwarded proto), and the TLS ingress in Kubernetes.
  //
  // No strict CSP: Next.js ships inline hydration scripts a `default-src 'self'`
  // policy would block; X-Frame-Options still covers clickjacking.
  async headers() {
    return [
      {
        source: "/:path*",
        headers: [
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
