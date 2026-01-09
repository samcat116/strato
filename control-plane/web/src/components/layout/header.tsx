"use client";

import { LogOut } from "lucide-react";
import { Button } from "@/components/ui/button";
import { useAuth } from "@/providers";
import { OrganizationSwitcher } from "./organization-switcher";

export function Header() {
  const { logout } = useAuth();

  return (
    <header className="bg-gray-900 shadow-sm border-b border-gray-700">
      <div className="flex items-center justify-between h-16 px-6">
        <div className="flex items-center">
          <h1 className="text-2xl font-bold text-blue-400">Strato</h1>
        </div>
        <div className="flex items-center space-x-4">
          <OrganizationSwitcher />
          <Button
            variant="ghost"
            size="sm"
            onClick={logout}
            className="text-gray-400 hover:text-gray-200"
          >
            <LogOut className="h-4 w-4 mr-2" />
            Logout
          </Button>
        </div>
      </div>
    </header>
  );
}
