"use client";

import { useState } from "react";
import { Check, ChevronDown, Plus } from "lucide-react";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { useOrganization } from "@/providers";
import { CreateOrganizationDialog } from "./create-organization-dialog";

export function OrganizationSwitcher() {
  const { currentOrg, organizations, switchOrg, isLoading, refresh } = useOrganization();
  const [open, setOpen] = useState(false);
  const [createDialogOpen, setCreateDialogOpen] = useState(false);

  const handleSwitch = async (orgId: string) => {
    await switchOrg(orgId);
    setOpen(false);
  };

  return (
    <DropdownMenu open={open} onOpenChange={setOpen}>
      <DropdownMenuTrigger asChild>
        <button className="mb-3.5 flex w-full items-center gap-2 rounded-[7px] border border-border bg-background px-[9px] py-[7px] transition-colors hover:bg-accent">
          <span className="h-4 w-4 shrink-0 rounded bg-gradient-to-br from-[#3c87dd] to-[#7c3aed]" />
          <span className="min-w-0 flex-1 truncate text-left text-[12.5px] font-semibold">
            {isLoading ? "Loading…" : currentOrg?.name || "Select organization"}
          </span>
          <ChevronDown className="h-3 w-3 shrink-0 text-muted-foreground" />
        </button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="start" className="w-56">
        <DropdownMenuLabel className="text-xs font-medium uppercase text-muted-foreground">
          Switch Organization
        </DropdownMenuLabel>
        <DropdownMenuSeparator />
        <div className="max-h-48 overflow-y-auto">
          {organizations.map((org) => (
            <DropdownMenuItem
              key={org.id}
              onClick={() => handleSwitch(org.id)}
              className="cursor-pointer"
            >
              <span className="flex-1 truncate">{org.name}</span>
              {currentOrg?.id === org.id && <Check className="h-4 w-4" />}
            </DropdownMenuItem>
          ))}
        </div>
        <DropdownMenuSeparator />
        <DropdownMenuItem
          onClick={() => {
            setOpen(false);
            setCreateDialogOpen(true);
          }}
          className="cursor-pointer"
        >
          <Plus className="mr-2 h-4 w-4" />
          Create New Organization
        </DropdownMenuItem>
      </DropdownMenuContent>
      <CreateOrganizationDialog
        open={createDialogOpen}
        onOpenChange={setCreateDialogOpen}
        onCreated={refresh}
      />
    </DropdownMenu>
  );
}
