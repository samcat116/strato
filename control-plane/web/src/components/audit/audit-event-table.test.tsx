import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { AuditEvent } from "@/types/api";
import { AuditEventTable } from "./audit-event-table";

const vmID = "7C265A66-B4DB-4EB1-82A7-91BF7FC30AE1";

function event(overrides: Partial<AuditEvent> = {}): AuditEvent {
  return {
    id: crypto.randomUUID(),
    eventType: "vm.command.completed",
    resourceType: "vms",
    resourceID: vmID,
    action: "vm:runCommand",
    adminBypass: false,
    metadata: {
      argv: JSON.stringify(["/usr/bin/printf", "hello world"]),
      outcome: "exited",
      correlationID: "command-1",
      exitCode: "7",
      correctsOutcome: "timed_out",
    },
    ...overrides,
  };
}

describe("AuditEventTable guest execution events", () => {
  afterEach(cleanup);

  it("renders bounded lifecycle metadata without losing argv boundaries", () => {
    render(<AuditEventTable events={[event()]} />);

    expect(screen.getByText("VM command completed")).toBeInTheDocument();
    expect(screen.getByText("vm.command.completed")).toBeInTheDocument();
    expect(screen.getAllByText('["/usr/bin/printf","hello world"]')).not.toHaveLength(0);
    expect(screen.getByText("exited")).toBeInTheDocument();
    expect(screen.getByText("exit 7")).toBeInTheDocument();

    fireEvent.click(screen.getByText("Details"));
    expect(screen.getByText("command-1")).toBeInTheDocument();
    expect(screen.getByText("timed_out")).toBeInTheDocument();
  });

  it("renders malformed argv safely", () => {
    render(
      <AuditEventTable
        events={[event({ metadata: { argv: "not-json", outcome: "failed" } })]}
      />
    );

    expect(screen.getByText("Arguments unavailable")).toBeInTheDocument();
    expect(screen.getByText("failed")).toBeInTheDocument();
  });

  it("never renders unrecognized terminal-content metadata", () => {
    render(
      <AuditEventTable
        events={[
          event({
            metadata: {
              argv: JSON.stringify(["/usr/bin/true"]),
              outcome: "exited",
              stdout: "SECRET_STDOUT_SENTINEL",
              stdin: "SECRET_STDIN_SENTINEL",
            },
          }),
        ]}
      />
    );

    expect(screen.queryByText("SECRET_STDOUT_SENTINEL")).not.toBeInTheDocument();
    expect(screen.queryByText("SECRET_STDIN_SENTINEL")).not.toBeInTheDocument();
  });

  it("turns a VM resource cell into a filter action", () => {
    const onFilterByVM = vi.fn();
    render(<AuditEventTable events={[event()]} onFilterByVM={onFilterByVM} />);

    fireEvent.click(screen.getByRole("button", { name: /vms 7C265A66/i }));

    expect(onFilterByVM).toHaveBeenCalledWith(vmID);
  });
});
