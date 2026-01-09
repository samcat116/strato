"use client";

import { useState } from "react";
import { Check, ChevronDown, Plus } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { useOrganization } from "@/providers";

export function OrganizationSwitcher() {
  const { currentOrg, organizations, switchOrg, isLoading } = useOrganization();
  const [open, setOpen] = useState(false);

  const handleSwitch = async (orgId: string) => {
    await switchOrg(orgId);
    setOpen(false);
  };

  return (
    <DropdownMenu open={open} onOpenChange={setOpen}>
      <DropdownMenuTrigger asChild>
        <Button
          variant="outline"
          className="bg-gray-800 hover:bg-gray-700 text-gray-200 border-gray-600"
        >
          {isLoading ? "Loading..." : currentOrg?.name || "Select Organization"}
          <ChevronDown className="ml-2 h-4 w-4 text-gray-500" />
        </Button>
      </DropdownMenuTrigger>
      <DropdownMenuContent className="w-64 bg-gray-800 border-gray-600">
        <DropdownMenuLabel className="text-xs font-medium text-gray-400 uppercase">
          Switch Organization
        </DropdownMenuLabel>
        <DropdownMenuSeparator className="bg-gray-700" />
        <div className="max-h-48 overflow-y-auto">
          {organizations.map((org) => (
            <DropdownMenuItem
              key={org.id}
              onClick={() => handleSwitch(org.id)}
              className="text-gray-200 hover:bg-gray-700 focus:bg-gray-700 cursor-pointer"
            >
              <span className="flex-1">{org.name}</span>
              {currentOrg?.id === org.id && (
                <Check className="h-4 w-4 text-blue-400" />
              )}
            </DropdownMenuItem>
          ))}
        </div>
        <DropdownMenuSeparator className="bg-gray-700" />
        <DropdownMenuItem className="text-blue-400 hover:bg-gray-700 focus:bg-gray-700 cursor-pointer">
          <Plus className="h-4 w-4 mr-2" />
          Create New Organization
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
