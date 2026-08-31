import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { useState } from "react";
import { describe, expect, it } from "vitest";
import {
  ConfirmationProvider,
  confirmAction,
} from "./confirmation-provider";

function Harness() {
  const [result, setResult] = useState("pending");
  return (
    <>
      <button
        onClick={async () => {
          const confirmed = await confirmAction({
            title: "Delete resource?",
            description: "This cannot be undone.",
            confirmLabel: "Delete",
          });
          setResult(confirmed ? "confirmed" : "cancelled");
        }}
      >
        Open confirmation
      </button>
      <output>{result}</output>
    </>
  );
}

describe("ConfirmationProvider", () => {
  it("resolves destructive actions only after explicit confirmation", async () => {
    render(
      <ConfirmationProvider>
        <Harness />
      </ConfirmationProvider>
    );

    fireEvent.click(screen.getByRole("button", { name: "Open confirmation" }));
    expect(
      await screen.findByRole("heading", { name: "Delete resource?" })
    ).toBeVisible();
    fireEvent.click(screen.getByRole("button", { name: "Delete" }));

    await waitFor(() => expect(screen.getByText("confirmed")).toBeVisible());
  });
});
