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

/**
 * What a create dialog says when there is no project to create into.
 *
 * It names a blocker rather than describing the form, because that is what it
 * now is: every create names its project and the API has no default to fall
 * back on (issue #1059), so with no project selected there is nothing the
 * dialog can submit.
 */
export const NO_PROJECT_DESCRIPTION =
  "No project selected — create or select a project first";

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

export function ProjectProvider({
  children,
  initialProjects,
  initialOrganizationId,
}: {
  children: ReactNode;
  initialProjects?: Project[];
  initialOrganizationId: string | null;
}) {
  const { currentOrg } = useOrganization();

  const orgId = currentOrg?.id;
  const { data: unsortedProjects = [], isLoading } = useProjectsForOrganization(
    orgId,
    orgId && orgId === initialOrganizationId ? initialProjects : undefined
  );

  // One global name order, because the API's is two orders concatenated:
  // `listOrganizationProjects` returns the organization's own projects sorted
  // by name, then every folder-held project sorted by name. So an
  // alphabetically-first project could never be picked below just for living in
  // a folder. Sorting here makes the pick depend on the set of projects rather
  // than on where in the hierarchy they hang.
  const projects = useMemo(
    () => [...unsortedProjects].sort((a, b) => a.name.localeCompare(b.name)),
    [unsortedProjects]
  );

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

  // Derive the active project: explicit selection > first project by name.
  //
  // This is a UI convenience with no server-side counterpart. The API has no
  // default project (issue #1059) — every create names the project it lands in
  // — so what this picks is only ever a pre-filled selection the user can see
  // in the switcher and change, never an answer sent on their behalf. Create
  // dialogs name it for that reason.
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
