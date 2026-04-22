# PSDevOps — Repository Governance & Deploy Automation

PowerShell module for automating repository classification, health diagnostics, deploy workflow generation, and application deployment across the **cacsi-dev** GitHub organization.

## Quick Start

```powershell
Import-Module PSDevOps

# 1. Classify a repo
Get-RepoInfo -Name gabinete_ui

# 2. Diagnose health
Test-RepoHealth -Name gabinete_ui

# 3. Generate deploy workflow
New-DeployWorkflow -Name gabinete_ui -OutputPath .github/workflows/deploy.yml

# 4. Deploy (from project root)
Publish-FlutterWeb -Publish       # Flutter web apps
Publish-NodeApi -Publish           # Node.js/TS APIs
Invoke-SqlPackage -Publish         # SQL Server databases
```

---

## Metadata Schema

Repository descriptions use a machine-parseable format: `key:value` pairs delimited by `|`.

```
type:flutter-web|stack:dart|deploy:v1.0.0|model:legacy
```

| Key | Values | Required |
|-----|--------|----------|
| `type` | flutter-web, flutter-apk, node-api, sqlserver-db, macss, tooling, documentation, archived, unknown | Yes |
| `stack` | dart, javascript, typescript, sql, csharp, generic | Yes |
| `deploy` | v[semver], none | Yes |
| `model` | legacy, monorepo | Yes |
| `ci` | github-actions, manual, none | No |
| `criticality` | critical, high, medium, low | No |

Full specification: `.github/docs/governance/METADATA_SCHEMA.md`

---

## Cmdlets

### Get-RepoInfo

Query metadata and deploy status of repositories.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `-Name` | string | Yes (Single) | Repository name |
| `-List` | switch | Yes (List) | List all org repos |
| `-Filter` | hashtable | No | Filter -List results by Type, HasMetadata, DeployStatus, Stack |
| `-Org` | string | No | GitHub org (default: cacsi-dev) |
| `-Json` | switch | No | Output as JSON |

**Output object properties:**

- `Name`, `URL`, `Description` — identity
- `HasMetadata`, `Type`, `Stack`, `RepoType` — parsed metadata
- `GitHubLanguage`, `GitHubTopics`, `IsArchived`, `LastPush` — GitHub API data
- `AutoDetectedStack`, `SuggestedType`, `SuggestedDescription` — auto-detection for repos without metadata
- `DeployStatus` (auto/partial/none), `DeployYAMLExists`, `WorkflowExists`, `TemplateVersion`, `TemplateIsCurrent` — deploy state

**Examples:**

```powershell
# Single repo info
Get-RepoInfo -Name gabinete_ui

# List all repos with metadata
Get-RepoInfo -List -Filter @{ HasMetadata = $true }

# Find repos without deploy automation
Get-RepoInfo -List -Filter @{ DeployStatus = 'none' }

# Export full inventory as JSON
Get-RepoInfo -List -Json | Out-File inventory.json

# Find all Flutter repos
Get-RepoInfo -List -Filter @{ Stack = 'dart' }
```

---

### Test-RepoHealth

Run health checks on a repository: metadata validity, deploy.yaml presence, workflow existence, template freshness.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `-Name` | string | Yes | Repository name |
| `-Org` | string | No | GitHub org (default: cacsi-dev) |
| `-Fix` | switch | No | Auto-remediate (not implemented yet) |

**Output object properties:**

- `Name` — repository name
- `HealthStatus` — healthy, degraded, unhealthy, archived
- `Checks` — array of `{ Check, Status, Suggestion }`
- `Actions` — recommended remediation steps

**Checks performed:**

1. Valid metadata description
2. deploy.yaml exists
3. Workflow file exists
4. Template version is current

**Examples:**

```powershell
# Diagnose a single repo
Test-RepoHealth -Name gabinete_ui

# Check all repos and find unhealthy ones
Get-RepoInfo -List | ForEach-Object { Test-RepoHealth -Name $_.Name } |
    Where-Object { $_.HealthStatus -ne 'healthy' }

# Show only actions needed
$health = Test-RepoHealth -Name my_api
$health.Actions
```

---

### New-DeployWorkflow

Generate a deploy workflow by copying the canonical template for the repo's type.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `-Name` | string | Yes | Repository name |
| `-OutputPath` | string | Yes | Full path for the generated workflow file |
| `-TemplatePath` | string | No | Directory with canonical templates (auto-resolved if omitted) |
| `-Push` | switch | No | Placeholder for git push after generation |

**Type → Template mapping:**

| Repo type | Template file |
|-----------|--------------|
| flutter-web | deploy.web.yml |
| flutter-apk | deploy.web.yml |
| node-api | deploy.api.yml |
| sqlserver-db | deploy.db.yml |

**Examples:**

```powershell
# Generate workflow for a Flutter web repo
New-DeployWorkflow -Name gabinete_ui -OutputPath .github/workflows/deploy.yml

# Generate with explicit template directory
New-DeployWorkflow -Name my_api -OutputPath .github/workflows/deploy.yml `
    -TemplatePath C:\Code\cacsi-dev\.github\templates\workflows
```

**Prerequisites:**
- Repo must have valid metadata description (run `Get-RepoInfo` first)
- Repo must have `deploy.yaml` (run `Publish-*` with `-Init` to generate)

---

### Publish-FlutterWeb

Build and deploy Flutter Web apps to a remote Linux server via SSH.

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `-Init` | switch | Generate deploy.yaml in current directory |
| `-Publish` | switch | Build, package, upload, and deploy |
| `-DeployReport` | switch | Dry-run: show what -Publish would do |

**deploy.yaml for flutter-web:**

```yaml
version: "1.0"
type: flutter-web
server: web-server     # alias from ~/.ssh/config
port: 8080             # nginx port
```

**Examples:**

```powershell
# First time: generate config
cd C:\Code\my_flutter_app
Publish-FlutterWeb -Init

# Preview what will happen
Publish-FlutterWeb -DeployReport

# Deploy
Publish-FlutterWeb -Publish
```

**Requires:** Flutter SDK, SSH config for server, nginx on server, powershell-yaml module.

---

### Publish-NodeApi

Deploy Node.js/TypeScript APIs to a remote Linux server via SSH.

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `-Init` | switch | Generate deploy.yaml and .env.production |
| `-Publish` | switch | Build, package, upload, and deploy |
| `-DeployReport` | switch | Dry-run: show what -Publish would do |

**deploy.yaml for node-api:**

```yaml
version: "1.0"
type: node-api
server: api-server
runtime:
  processManager: systemd   # or pm2
  nodeVersion: ">=18"
health:
  retries: 3
  interval: 5
```

**Examples:**

```powershell
cd C:\Code\my_node_api
Publish-NodeApi -Init
Publish-NodeApi -DeployReport
Publish-NodeApi -Publish
```

**Requires:** Node.js/npm locally, Node.js runtime on server, systemd or PM2, SSH config, powershell-yaml module.

---

### Invoke-SqlPackage

Declarative SQL Server database deployment via sqlpackage.exe.

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `-Init` | switch | Generate sqlpackage.yaml and .env |
| `-Publish` | switch | Build dacpac and deploy to server |
| `-DeployReport` | switch | Show diff without modifying database |
| `-Script` | switch | Generate .sql script of changes |
| `-Extract` | switch | Capture current server schema as dacpac |
| `-Export` | switch | Export schema + data as bacpac |
| `-Import` | switch | Import bacpac to server |

**Examples:**

```powershell
cd C:\Code\my_sql_project
Invoke-SqlPackage -Init
Invoke-SqlPackage -DeployReport
Invoke-SqlPackage -Publish
Invoke-SqlPackage -Script
Invoke-SqlPackage -Extract
```

**Requires:** sqlpackage.exe in PATH, dotnet SDK, .sqlproj file, sqlpackage.yaml + .env configured.

---

## Common Workflows

### Classify a new repo

```powershell
# 1. Check current state
$info = Get-RepoInfo -Name my_new_repo
$info.SuggestedDescription   # auto-detected suggestion

# 2. Apply metadata (if suggestion is correct)
gh api -X PATCH repos/cacsi-dev/my_new_repo `
    -f description="$($info.SuggestedDescription)"

# 3. Verify
Get-RepoInfo -Name my_new_repo | Select-Object Name, HasMetadata, Type, Stack
```

### Automate deploy for a classified repo

```powershell
# 1. Diagnose
Test-RepoHealth -Name my_repo

# 2. Generate deploy config (from project root)
Publish-FlutterWeb -Init    # or Publish-NodeApi -Init, or Invoke-SqlPackage -Init

# 3. Generate workflow
New-DeployWorkflow -Name my_repo -OutputPath .github/workflows/deploy.yml

# 4. Verify health
Test-RepoHealth -Name my_repo
```

### Org-wide audit

```powershell
# Full inventory
$repos = Get-RepoInfo -List

# Summary
$repos | Group-Object Type | Sort-Object Count -Descending |
    Format-Table Name, Count

# Repos needing attention
$repos | Where-Object { -not $_.HasMetadata } |
    Select-Object Name, SuggestedDescription |
    Format-Table -AutoSize
```

---

## Deploy YAML Schema Reference

| Field | Type | flutter-web | node-api | sqlserver-db |
|-------|------|-------------|----------|--------------|
| `version` | string | "1.0" | "1.0" | "1.0" |
| `type` | string | flutter-web | node-api | sqlserver-db |
| `server` | string | alias | alias | — |
| `port` | int | nginx port | — | — |
| `runtime.processManager` | string | — | systemd/pm2 | — |
| `runtime.nodeVersion` | string | — | ">=18" | — |
| `health.retries` | int | — | 3 | — |
| `health.interval` | int | — | 5 (seconds) | — |

Full specification: `.github/docs/governance/DEPLOY_YAML_SCHEMA.md`

---

## Installation

```powershell
# Install SKILL.md as VS Code prompt file
Install-PSDevOpsSkill
```
