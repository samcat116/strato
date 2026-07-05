"use client";

import {
  createContext,
  useContext,
  useState,
  useCallback,
  useMemo,
  type ReactNode,
} from "react";
import { useProjectsForOrganization } from "@/lib/hooks/use-projects";
import { useOrganization } from "./organization-provider";
import type { Project } from "@/lib/api/projects";

interface ProjectContextType {
  /** The project currently in scope for VM/image lists, or null if the org has none. */
  currentProject: Project | null;
  /** Projects belonging to the current organization. */
  projects: Project[];
  isLoading: boolean;
  switchProject: (projectId: string) => void;
}

const ProjectContext = createContext<ProjectContextType | undefined>(undefined);

/** localStorage key namespacing the remembered project per organization. */
function storageKey(orgId: string) {
  return `strato.selectedProject.${orgId}`;
}

function readStoredProject(orgId: string): string | null {
  if (typeof window === "undefined") return null;
  try {
    return window.localStorage.getItem(storageKey(orgId));
  } catch {
    return null;
  }
}

function writeStoredProject(orgId: string, projectId: string) {
  if (typeof window === "undefined") return;
  try {
    window.localStorage.setItem(storageKey(orgId), projectId);
  } catch {
    // Ignore storage failures (private mode, quota, etc.)
  }
}

export function ProjectProvider({ children }: { children: ReactNode }) {
  const { currentOrg } = useOrganization();

  const orgId = currentOrg?.id;
  const { data: projects = [], isLoading } = useProjectsForOrganization(orgId);

  // User's explicit selection for the current org, seeded from persisted state.
  // When the org changes we re-derive the selection during render (the React-
  // recommended alternative to a setState-in-effect) so switchers stay in sync.
  const [selectedProjectId, setSelectedProjectId] = useState<string | null>(
    () => (orgId ? readStoredProject(orgId) : null)
  );
  const [seededOrgId, setSeededOrgId] = useState(orgId);
  if (orgId !== seededOrgId) {
    setSeededOrgId(orgId);
    setSelectedProjectId(orgId ? readStoredProject(orgId) : null);
  }

  // Derive the active project: explicit selection > first project in the org.
  const currentProject = useMemo(() => {
    if (projects.length === 0) return null;
    if (selectedProjectId) {
      const match = projects.find((p) => p.id === selectedProjectId);
      if (match) return match;
    }
    return projects[0];
  }, [projects, selectedProjectId]);

  const switchProject = useCallback(
    (projectId: string) => {
      setSelectedProjectId(projectId);
      if (orgId) writeStoredProject(orgId, projectId);
    },
    [orgId]
  );

  return (
    <ProjectContext.Provider
      value={{ currentProject, projects, isLoading, switchProject }}
    >
      {children}
    </ProjectContext.Provider>
  );
}

export function useProjectContext() {
  const context = useContext(ProjectContext);
  if (!context) {
    throw new Error("useProjectContext must be used within ProjectProvider");
  }
  return context;
}
