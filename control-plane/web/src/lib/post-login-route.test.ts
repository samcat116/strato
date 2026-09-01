import { beforeEach, describe, expect, it } from "vitest";
import {
  loginHrefFor,
  rememberPostLoginPath,
  resolvePostLoginPath,
  safePostLoginPath,
} from "./post-login-route";

describe("post-login navigation", () => {
  beforeEach(() => window.sessionStorage.clear());

  it("preserves an application deep link including its query and hash", () => {
    const path = "/vms/vm-1?tab=console#output";

    expect(safePostLoginPath(path)).toBe(path);
    expect(loginHrefFor(path)).toBe(
      "/login?next=%2Fvms%2Fvm-1%3Ftab%3Dconsole%23output"
    );
  });

  it.each([
    "https://attacker.example/path",
    "//attacker.example/path",
    "/login",
    "/register",
    "/claim",
  ])("rejects unsafe or looping destination %s", (candidate) => {
    expect(safePostLoginPath(candidate)).toBe("/dashboard");
  });

  it("carries the destination across an external SSO round trip once", () => {
    rememberPostLoginPath("/storage/volumes?page=2");

    expect(resolvePostLoginPath(null, true)).toBe("/storage/volumes?page=2");
    expect(resolvePostLoginPath(null, true)).toBe("/dashboard");
  });

  it("clears a stale SSO destination when an explicit return path wins", () => {
    rememberPostLoginPath("/agents");

    expect(resolvePostLoginPath("/vms", true)).toBe("/vms");
    expect(resolvePostLoginPath(null, true)).toBe("/dashboard");
  });
});
