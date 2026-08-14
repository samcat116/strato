import { describe, expect, it } from "vitest";
import type { Project } from "@/lib/api/projects";
import type { FolderNode, OrganizationNode, ProjectNode } from "@/types/api";
import {
  buildProjectFolderOptions,
  buildProjectTableRows,
} from "./project-table-model";

function project(id: string, name: string): Project {
  return {
    id,
    name,
    description: `${name} description`,
    organizationId: "org-1",
    path: `/org-1/${id}`,
    defaultEnvironment: "development",
    environments: ["development"],
    vmCount: 0,
  };
}

function folder(
  id: string,
  name: string,
  projects: FolderNode["projects"] = [],
  childOUs: FolderNode[] = []
): FolderNode {
  return {
    id,
    name,
    description: "",
    path: `/org-1/${id}`,
    depth: 0,
    projects,
    childOUs,
    quotas: [],
  };
}

function projectNode(value: Project): ProjectNode {
  return {
    id: value.id,
    name: value.name,
    description: value.description,
    path: value.path,
    defaultEnvironment: value.defaultEnvironment,
    environments: value.environments,
    vms: [],
    quotas: [],
  };
}

const rootProject = project("project-root", "Root project");
const nestedProject = project("project-nested", "Nested project");
const organization: OrganizationNode = {
  id: "org-1",
  name: "Acme",
  description: "",
  quotas: [],
  projects: [projectNode(rootProject)],
  organizationalUnits: [
    folder("folder-product", "Product", [], [
      folder("folder-platform", "Platform", [projectNode(nestedProject)]),
    ]),
  ],
};

describe("project table hierarchy model", () => {
  it("sorts projects by folder hierarchy and records their location", () => {
    const rows = buildProjectTableRows(
      [nestedProject, rootProject],
      organization,
      ""
    );

    expect(rows.map(({ project }) => project.id)).toEqual([
      "project-root",
      "project-nested",
    ]);
    expect(rows[0].folderPath).toEqual([]);
    expect(rows[1].folderPath).toEqual(["Product", "Platform"]);
  });

  it("matches a project through its folder path", () => {
    const rows = buildProjectTableRows(
      [rootProject, nestedProject],
      organization,
      "platform"
    );

    expect(rows.map(({ project }) => project.id)).toEqual(["project-nested"]);
  });

  it("builds selectable folder breadcrumbs for project creation", () => {
    expect(buildProjectFolderOptions(organization)).toEqual([
      { id: "folder-product", label: "Product" },
      { id: "folder-platform", label: "Product / Platform" },
    ]);
  });
});
