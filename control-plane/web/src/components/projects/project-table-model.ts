import type { Project } from "@/lib/api/projects";
import type { FolderNode, OrganizationNode } from "@/types/api";

export interface ProjectTableRow {
  project: Project;
  /** Folder names from the organization root, or null when they are unavailable. */
  folderPath: string[] | null;
}

export interface ProjectFolderOption {
  id: string;
  label: string;
}

function visitFolder(
  folder: FolderNode,
  ancestors: string[],
  projectPaths: Map<string, string[]>,
  folderOptions: ProjectFolderOption[]
) {
  const folderPath = [...ancestors, folder.name];
  folderOptions.push({ id: folder.id, label: folderPath.join(" / ") });

  for (const project of folder.projects) {
    projectPaths.set(project.id, folderPath);
  }
  for (const child of folder.childOUs) {
    visitFolder(child, folderPath, projectPaths, folderOptions);
  }
}

function hierarchyIndex(organization?: OrganizationNode) {
  const projectPaths = new Map<string, string[]>();
  const folderOptions: ProjectFolderOption[] = [];

  if (!organization) return { projectPaths, folderOptions };

  for (const project of organization.projects) {
    projectPaths.set(project.id, []);
  }
  for (const folder of organization.organizationalUnits) {
    visitFolder(folder, [], projectPaths, folderOptions);
  }

  return { projectPaths, folderOptions };
}

export function buildProjectTableRows(
  projects: Project[],
  organization: OrganizationNode | undefined,
  query: string
): ProjectTableRow[] {
  const projectPaths = hierarchyIndex(organization).projectPaths;
  const normalizedQuery = query.trim().toLocaleLowerCase();

  return projects
    .map((project) => ({
      project,
      folderPath:
        projectPaths.get(project.id) ??
        (project.organizationalUnitId ? null : []),
    }))
    .filter(({ project, folderPath }) => {
      if (!normalizedQuery) return true;
      return [
        project.name,
        project.description,
        organization?.name ?? "",
        ...(folderPath ?? []),
      ].some((value) => value.toLocaleLowerCase().includes(normalizedQuery));
    })
    .sort((left, right) => {
      const leftLocation = left.folderPath?.join("\u0000") ?? "\uffff";
      const rightLocation = right.folderPath?.join("\u0000") ?? "\uffff";
      const locationOrder = leftLocation.localeCompare(rightLocation);
      return locationOrder || left.project.name.localeCompare(right.project.name);
    });
}

export function buildProjectFolderOptions(
  organization: OrganizationNode | undefined
): ProjectFolderOption[] {
  return hierarchyIndex(organization).folderOptions.sort((left, right) =>
    left.label.localeCompare(right.label)
  );
}
