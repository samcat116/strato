import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { ApiError } from "@/lib/api/client";
import { DetailQueryError } from "./detail-query-error";

describe("DetailQueryError", () => {
  afterEach(cleanup);

  it("offers a retry and preserves the API message for transient failures", () => {
    const retry = vi.fn();
    render(
      <DetailQueryError
        resourceName="VM"
        backHref="/vms"
        backLabel="Back to VMs"
        error={new ApiError(503, "The control plane is restarting")}
        onRetry={retry}
      />
    );

    expect(screen.getByRole("alert")).toHaveTextContent("Unable to load vm");
    expect(screen.getByRole("alert")).toHaveTextContent(
      "The control plane is restarting"
    );
    fireEvent.click(screen.getByRole("button", { name: "Try again" }));
    expect(retry).toHaveBeenCalledOnce();
  });

  it("shows a stable not-found state without a pointless retry", () => {
    render(
      <DetailQueryError
        resourceName="Image"
        backHref="/images"
        backLabel="Back to Images"
        error={new ApiError(404, "Not found")}
        onRetry={vi.fn()}
      />
    );

    expect(screen.getByRole("heading", { name: "Image not found" })).toBeVisible();
    expect(screen.queryByRole("button", { name: "Try again" })).toBeNull();
    expect(screen.getByRole("link", { name: "Back to Images" })).toHaveAttribute(
      "href",
      "/images"
    );
  });
});
