import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  output: "standalone", // Creates minimal server bundle for Docker
  images: {
    unoptimized: true,
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
