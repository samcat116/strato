import { NextResponse } from "next/server";
import type { NextRequest } from "next/server";
import { isControlPlanePath } from "@/lib/control-plane-routes";
import {
  GRAVATAR_COOKIE,
  GRAVATAR_ENV_VAR,
  parseGravatarEnabled,
} from "@/lib/gravatar";

export function proxy(request: NextRequest) {
  const apiUrl = process.env.STRATO_API_URL;
  const response =
    apiUrl && isControlPlanePath(request.nextUrl.pathname)
      ? NextResponse.rewrite(
          new URL(`${request.nextUrl.pathname}${request.nextUrl.search}`, apiUrl)
        )
      : NextResponse.next();

  if (request.headers.get("x-forwarded-proto") === "https") {
    response.headers.set(
      "Strict-Transport-Security",
      "max-age=31536000; includeSubDomains"
    );
  }

  response.cookies.set(
    GRAVATAR_COOKIE,
    parseGravatarEnabled(process.env[GRAVATAR_ENV_VAR]) ? "1" : "0",
    { httpOnly: false, sameSite: "lax", path: "/" }
  );

  return response;
}

export const config = {
  matcher: ["/((?!_next/static|_next/image|favicon.ico).*)"],
};
