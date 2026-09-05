# Log Analytics repository map

A Copilot skill that builds a compact local catalog of `AM-*` repositories,
records evidence-backed cross-repository references, and ranks repositories for a
Log Analytics question.

Generated catalogs remain local by default; the reusable skill can be stored in
GitHub without publishing internal architecture metadata.

## Install

Clone this repository, then create a directory junction:

```powershell
New-Item -ItemType Junction `
  -Path "$env:USERPROFILE\.copilot\skills\log-analytics-repo-map" `
  -Target "<clone path>"
```

## Build the local catalog

```powershell
.\scripts\Build-RepoIndex.ps1 -RootPath C:\LA
```

The default output is:

```text
C:\LA\.log-analytics-index\catalog.json
```

## Find relevant repositories

```powershell
.\scripts\Find-RelevantRepos.ps1 `
  -CatalogPath C:\LA\.log-analytics-index\catalog.json `
  -Question "Where is query scheduling configured?"
```

Use `-AsJson` for machine-readable results.

## Publish the skill

The repository is intentionally independent from generated data. Add a GitHub
remote and push normally:

```powershell
git remote add origin <private-repository-url>
git push -u origin main
```

Review any files before publishing. Do not add a generated catalog unless its
internal metadata is explicitly approved for that destination.
