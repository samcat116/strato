"use client";

import {
  createContext,
  useContext,
  useEffect,
  useRef,
  useState,
  useCallback,
  type ReactNode,
} from "react";
import { useQueryClient } from "@tanstack/react-query";
import { authApi } from "@/lib/api/auth";
import { webAuthnClient, WebAuthnClient } from "@/lib/webauthn";
import type { CreateUserRequest, User } from "@/types/api";

interface AuthContextType {
  user: User | null;
  isLoading: boolean;
  isAuthenticated: boolean;
  sessionError: Error | null;
  isWebAuthnSupported: boolean;
  login: (username?: string | null) => Promise<void>;
  register: (data: CreateUserRequest) => Promise<void>;
  logout: () => Promise<void>;
  refresh: () => Promise<void>;
}

const AuthContext = createContext<AuthContextType | undefined>(undefined);

export function AuthProvider({
  children,
  initialUser,
  initialError,
  refreshOnMount,
}: {
  children: ReactNode;
  initialUser: User | null;
  initialError: string | null;
  refreshOnMount: boolean;
}) {
  const [user, setUser] = useState<User | null>(initialUser);
  const [isLoading, setIsLoading] = useState(refreshOnMount);
  const [sessionError, setSessionError] = useState<Error | null>(() =>
    initialError ? new Error(initialError) : null
  );
  const [isWebAuthnSupported, setIsWebAuthnSupported] = useState(false);
  const userIdRef = useRef<string | null>(initialUser?.id ?? null);
  const queryClient = useQueryClient();

  const adoptUser = useCallback(
    (nextUser: User | null) => {
      const nextUserId = nextUser?.id ?? null;
      if (userIdRef.current !== nextUserId) {
        queryClient.clear();
        userIdRef.current = nextUserId;
      }
      setUser(nextUser);
    },
    [queryClient]
  );

  const refresh = useCallback(async () => {
    try {
      const session = await authApi.getSession();
      adoptUser(session?.user ?? null);
      setSessionError(null);
    } catch (error) {
      setSessionError(
        error instanceof Error ? error : new Error("Unable to verify your session")
      );
    } finally {
      setIsLoading(false);
    }
  }, [adoptUser]);

  useEffect(() => {
    if (refreshOnMount) void refresh();
    setIsWebAuthnSupported(WebAuthnClient.isSupported());
  }, [refresh, refreshOnMount]);

  const login = async (username?: string | null) => {
    const result = await webAuthnClient.authenticate(username);
    if (result.success) {
      adoptUser(result.user);
      setSessionError(null);
    } else {
      throw new Error("Authentication failed");
    }
  };

  const register = async (data: CreateUserRequest) => {
    const result = await webAuthnClient.register(data);
    if (result.success) {
      adoptUser(result.user);
      setSessionError(null);
    } else {
      throw new Error("Registration failed");
    }
  };

  const logout = async () => {
    const { sloUrl } = await authApi.logout();
    adoptUser(null);
    if (sloUrl) {
      // OIDC single logout: a full navigation to the IdP ends its session;
      // the IdP redirects back to /login afterwards.
      window.location.assign(sloUrl);
      return;
    }
    window.location.assign("/login");
  };

  return (
    <AuthContext.Provider
      value={{
        user,
        isLoading,
        isAuthenticated: !!user,
        sessionError,
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
