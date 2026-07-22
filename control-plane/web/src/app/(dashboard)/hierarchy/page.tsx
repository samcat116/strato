import { redirect } from "next/navigation";

// The hierarchy view was merged into the Projects page. Keep this route as a
// permanent redirect so existing links and bookmarks keep working.
export default function HierarchyPage() {
  redirect("/projects");
}
