# CSC Leasing SQL MCP Server — Setup Guide

## What This Does

Connects Claude Desktop to CSC's Azure SQL data warehouse (`lw_csc`). Once installed, you can ask Claude questions like "show me the top 10 accounts by lease exposure" and it queries the database directly.

## Prerequisites (Before Running the Installer)

### 1. Azure AD Access to `lw_csc`

You need to be granted access to the Azure SQL database. Ask Hunter or IT to:
- Add your `@cscleasing.com` account to the `lw_csc` database on `csc-leasing-analytics-sql01-prod.database.windows.net`
- Grant `db_datareader` role

**Test this first** — if you can connect via SSMS or Azure Data Studio with your CSC credentials, you're good.

### 2. Claude Desktop

Install Claude Desktop from https://claude.ai/download (Windows Store version works fine).

### 3. Python 3.10+

The installer will attempt to install Python via `winget` if not found, but it's cleaner to have it pre-installed. Download from https://python.org if needed. **Make sure "Add to PATH" is checked during install.**

### 4. ODBC Driver 18 for SQL Server

Usually already installed on CSC machines. The installer checks and installs via `winget` if missing.

## Installation

1. Copy the entire `csc-mcp-server` folder to your machine (or pull from the shared drive)
2. Open PowerShell and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-windows.ps1
```

Or: right-click `install-windows.ps1` → "Run with PowerShell"

The installer will:
- Check/install Python, ODBC Driver, Azure CLI
- Copy server files to `%USERPROFILE%\csc-mcp-server`
- Create a Python virtual environment with dependencies
- Prompt you to `az login` (opens browser for Azure auth)
- Test the database connection
- Configure Claude Desktop to use the MCP server

3. **Quit Claude Desktop completely** (right-click system tray icon → Quit)
4. Reopen Claude Desktop
5. Go to **Settings → Developer** — verify `csc-sql` shows as "running"
6. Test: ask Claude *"How many records are in the Opportunity table?"*

## What Gets Installed Where

| Item | Location |
|------|----------|
| Server files | `%USERPROFILE%\csc-mcp-server\` |
| Python venv | `%USERPROFILE%\csc-mcp-server\.venv\` |
| Claude config | `%LOCALAPPDATA%\Packages\Claude_*\...\claude_desktop_config.json` |
| Azure credentials | `%USERPROFILE%\.azure\` (managed by `az login`) |

## Daily Use

The Azure token expires roughly every hour. When queries start failing with auth errors:

```powershell
az login
```

That's it. No need to restart Claude Desktop — the server re-authenticates on the next query.

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `csc-sql` not showing in Developer settings | Quit and reopen Claude Desktop. Check `claude_desktop_config.json` has the `csc-sql` entry. |
| "Azure token expired" errors | Run `az login` in any terminal |
| Query timeout errors | Query ran longer than 2 min. Add `TOP` or `WHERE` filters. |
| "ODBC Driver not found" | Install from https://go.microsoft.com/fwlink/?linkid=2266337 |
| Python import errors | Re-run the installer — it recreates the venv |
| Server logs | Check `%APPDATA%\Claude\logs\mcp*.log` for detailed errors |

## Receiving Updates

There are three ways to get updates. All are supported — use whichever fits your setup.

### Option A: Git auto-updates (recommended)

If git is installed on your machine, the installer automatically clones the repo into `%USERPROFILE%\csc-mcp-server\.repo\`. After that, pull updates with:

```powershell
cd %USERPROFILE%\csc-mcp-server
powershell -ExecutionPolicy Bypass -File update-windows.ps1
```

This pulls the latest `server.py`, `context.md`, and `requirements.txt` from git, copies them into the install directory, and updates venv packages if needed. No Claude Desktop restart required — changes take effect on the next query.

### Option B: Re-run the installer

If someone sends you updated files, drop them in the `csc-mcp-server` folder and re-run:

```powershell
powershell -ExecutionPolicy Bypass -File install-windows.ps1
```

Safe to re-run anytime. It will update server files, recreate or update the venv, back up your existing Claude config before modifying, and skip steps that are already complete.

### Option C: Manual file copy

If you just need a quick hotfix, copy the updated `server.py` and/or `context.md` directly into `%USERPROFILE%\csc-mcp-server\`. No restart needed.

## Files in This Package

| File | Purpose |
|------|---------|
| `install-windows.ps1` | Automated installer (checks prereqs, creates venv, configures Claude) |
| `update-windows.ps1` | Update script (git pull + redeploy) |
| `install-mac.sh` | Mac installer (for future use) |
| `server.py` | The MCP server — handles Claude ↔ SQL communication |
| `context.md` | Domain knowledge loaded by the `get_context` tool |
| `requirements.txt` | Python dependencies |
| `SETUP.md` | This file |
