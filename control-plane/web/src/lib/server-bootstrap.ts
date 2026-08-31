import "server-only";

import { cache } from "react";
import { headers } from "next/headers";
import { loadFrontendBootstrap } from "@/lib/bootstrap-data";

function runtimeControlPlaneOrigin(): string | null {
  const configured =
    process.env.STRATO_API_URL ??
    (process.env.NODE_ENV === "development"
      ? process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8080"
      : null);

  if (!configured) return null;
  return new URL(configured).origin;
}

/** One bootstrap request per incoming render, shared by any future server consumers. */
export const getFrontendBootstrap = cache(async () => {
  const requestHeaders = await headers();
  return loadFrontendBootstrap(
    runtimeControlPlaneOrigin(),
    requestHeaders.get("cookie") ?? ""
  );
});
