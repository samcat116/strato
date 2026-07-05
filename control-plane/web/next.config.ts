import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  output: "standalone", // Creates minimal server bundle for Docker
  images: {
    unoptimized: true,
  },

  // Security headers for the user-facing HTML this service serves (/, /login,
  // ...). In the compose/Helm topologies these pages come from here, not the
  // control plane, so the control plane's SecurityHeadersMiddleware doesn't cover
  // them — mirror the same headers here. HSTS is gated on HTTP_TLS_ENABLED so it's
  // only sent when browsers reach us over HTTPS (see the control plane's rationale).
  // No strict CSP: Next.js ships inline hydration scripts a `default-src 'self'`
  // policy would block; X-Frame-Options still covers clickjacking.
  async headers() {
    const headers = [
      { key: "X-Content-Type-Options", value: "nosniff" },
      { key: "X-Frame-Options", value: "DENY" },
      { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
    ];
    if (process.env.HTTP_TLS_ENABLED === "true") {
      headers.push({
        key: "Strict-Transport-Security",
        value: "max-age=31536000; includeSubDomains",
      });
    }
    return [{ source: "/:path*", headers }];
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
