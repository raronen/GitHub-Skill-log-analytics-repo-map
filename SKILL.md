---
name: log-analytics-repo-map
description: Quickly identify which local Log Analytics repositories are relevant to a question by querying a durable repository catalog and evidence-backed relationship graph, then verify the answer in current source. Use for questions about Log Analytics architecture, ownership, APIs, deployments, dependencies, components, services, incidents, or cross-repository flows when the workspace contains the AM-* repositories.
---

# Log Analytics repository map

Use the local repository catalog to shortlist relevant repositories before
investigating source code.

## Invocation

Natural-language triggers include:

- "Which Log Analytics repositories are relevant to this?"
- "Where is this Log Analytics feature implemented?"
- "How do these Log Analytics services relate?"
- "Trace this flow across Log Analytics."
- "Which repo owns this API, deployment, or component?"

## Required workflow

1. Locate the workspace root. Prefer `C:\LA` when it exists.
2. Locate the catalog at `<workspace>\.log-analytics-index\catalog.json`.
3. If the catalog is missing, run:

   ```powershell
   & "<skill>\scripts\Build-RepoIndex.ps1" -RootPath "<workspace>"
   ```

4. If repository HEADs differ from `sourceCommit` values in the catalog, or the
   question depends on recent changes, refresh the catalog before ranking.
5. Rank repositories with:

   ```powershell
   & "<skill>\scripts\Find-RelevantRepos.ps1" `
     -CatalogPath "<workspace>\.log-analytics-index\catalog.json" `
     -Question "<user question>"
   ```

6. Treat ranking as a shortlist, not as proof. Inspect current files in the
   highest-ranked repositories and follow evidence-backed relationship edges.
7. Add lower-ranked repositories only when source evidence crosses into them.
8. Cite repository names and relevant source paths in the answer.

## Catalog semantics

The catalog contains:

- repository identity, path, remote, branch, and indexed commit;
- a short README-derived description;
- role, technologies, manifests, and path-derived keywords;
- directed `reference` relationships;
- bounded source-file evidence for every relationship.

Relationship direction `A -> B` means tracked content in repository A names
repository B. It does not prove a runtime call. Determine whether an edge is a
build, deployment, documentation, package, API, or runtime dependency by reading
the cited evidence.

## Relevance rules

Prefer:

1. exact repository-name and role matches;
2. description, technology, manifest, and path-keyword matches;
3. directly connected repositories with evidence;
4. current source confirmation.

Do not load every repository for each question. Start with the top five to eight
results and expand through relevant relationship edges.

## Privacy and publication

The scripts and schema are portable and safe to version independently. Generated
catalogs can contain internal repository names, local paths, remotes, descriptions,
and architecture clues.

- Keep generated catalogs local by default.
- Never commit or publish a generated catalog without explicit user approval and
  a content review.
- Do not copy source code into the catalog.
- Relationship evidence stores paths and line numbers, not source text.

## Refresh behavior

Indexing is deterministic for the same tracked files and commits. Rebuild after:

- cloning, removing, or renaming a repository;
- substantial dependency or deployment changes;
- switching important branches;
- observing stale ranking.

The default discovery pattern is `AM-*`, which excludes this skill and unrelated
repositories.
