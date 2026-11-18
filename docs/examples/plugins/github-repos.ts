#!/usr/bin/env bun
// Your GitHub repositories (via the authenticated `gh` CLI), filtered by the query.
// Enter opens the repo, ⌘Enter copies the clone URL, ⌘K also offers "Open Issues".
import { $ } from "bun";

const query = (process.argv[2] ?? "").toLowerCase();

type Repo = { nameWithOwner: string; description: string | null; url: string; sshUrl: string; isPrivate: boolean };

let repos: Repo[];
try {
  repos = await $`gh repo list --limit 200 --json nameWithOwner,description,url,sshUrl,isPrivate`.json();
} catch (e) {
  // Errors become a single item instead of a crash, so they show in the launcher.
  console.log(JSON.stringify({ items: [{ title: "gh failed", subtitle: String(e).slice(0, 200), icon: "exclamationmark.triangle" }] }));
  process.exit(0);
}

const items = repos
  .filter((r) => !query || r.nameWithOwner.toLowerCase().includes(query) || (r.description ?? "").toLowerCase().includes(query))
  .slice(0, 50)
  .map((r) => ({
    id: r.nameWithOwner,
    title: r.nameWithOwner,
    subtitle: r.description ?? "",
    icon: r.isPrivate ? "lock" : "book.closed",
    accessory: r.isPrivate ? "private" : "",
    actions: [
      { title: "Open", open: r.url },
      { title: "Copy Clone URL", copy: r.sshUrl },
      { title: "Open Issues", open: `${r.url}/issues` },
    ],
  }));

console.log(JSON.stringify({ items }));
