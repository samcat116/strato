"use client";

import {
  createContext,
  useContext,
  useEffect,
  useState,
  useCallback,
  type ReactNode,
} from "react";
import { useRouter } from "next/navigation";
import { authApi } from "@/lib/api/auth";
import { webAuthnClient, WebAuthnClient } from "@/lib/webauthn";
import type { User } from "@/types/api";

interface AuthContextType {
  user: User | null;
  isLoading: boolean;
  isAuthenticated: boolean;
  isWebAuthnSupported: boolean;
  login: (username?: string | null) => Promise<void>;
  register: (username: string) => Promise<void>;
  logout: () => Promise<void>;
  refresh: () => Promise<void>;
}

const AuthContext = createContext<AuthContextType | undefined>(undefined);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<User | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [isWebAuthnSupported, setIsWebAuthnSupported] = useState(false);
  const router = useRouter();

  const refresh = useCallback(async () => {
    try {
      const session = await authApi.getSession();
      setUser(session?.user || null);
    } catch {
      setUser(null);
    } finally {
      setIsLoading(false);
    }
  }, []);

  useEffect(() => {
    refresh();
    setIsWebAuthnSupported(WebAuthnClient.isSupported());
  }, [refresh]);

  const login = async (username?: string | null) => {
    const result = await webAuthnClient.authenticate(username);
    if (result.success) {
      setUser(result.user);
      router.push("/dashboard");
    } else {
      throw new Error("Authentication failed");
    }
  };

  const register = async (username: string) => {
    const result = await webAuthnClient.register(username);
    if (result.success) {
      setUser(result.user);
      router.push("/dashboard");
    } else {
      throw new Error("Registration failed");
    }
  };

  const logout = async () => {
    await authApi.logout();
    setUser(null);
    router.push("/login");
  };

  return (
    <AuthContext.Provider
      value={{
        user,
        isLoading,
        isAuthenticated: !!user,
        isWebAuthnSupported,
        login,
        register,
        logout,
        refresh,
      }}
    >
      {children}
    </AuthContext.Provider>
  );
}

export function useAuth() {
  const context = useContext(AuthContext);
  if (!context) {
    throw new Error("useAuth must be used within AuthProvider");
  }
  return context;
}
