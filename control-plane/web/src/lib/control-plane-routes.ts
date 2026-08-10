import routePrefixes from "./control-plane-route-prefixes.json";

export const controlPlaneRoutePrefixes: readonly string[] = routePrefixes;

export function isControlPlanePath(pathname: string): boolean {
  return controlPlaneRoutePrefixes.some(
    (prefix) => pathname === prefix || pathname.startsWith(`${prefix}/`),
  );
}
