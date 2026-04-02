# ============================================================
# CSC Leasing SQL MCP Server — Update Script
# Pulls latest server files from git and redeploys to install dir.
# Run: powershell -ExecutionPolicy Bypass -File update-windows.ps1
# ============================================================

$ErrorActionPreference = "Stop"

function Write-OK($msg)   { Write-Host "[OK]   $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "[!]    $msg" -ForegroundColor Yellow }
function Write-Fail($msg) { Write-Host "[FAIL] $msg" -ForegroundColor Red; exit 1 }

$INSTALL_DIR = "$env:USERPROFILE\csc-mcp-server"
$REPO_DIR = "$INSTALL_DIR\.repo"

Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "  CSC MCP Server — Update"               -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""

# -----------------------------------------------------------
# 1. Verify install exists
# -----------------------------------------------------------
if (-not (Test-Path "$INSTALL_DIR\server.py")) {
    Write-Fail "No existing install found at $INSTALL_DIR. Run install-windows.ps1 first."
}

# -----------------------------------------------------------
# 2. Pull latest from git (if repo exists)
# -----------------------------------------------------------
if (Test-Path "$REPO_DIR\.git") {
    Write-Host "--- Pulling latest from git ---"
    Push-Location $REPO_DIR
    $branch = git rev-parse --abbrev-ref HEAD 2>$null
    $beforeHash = git rev-parse HEAD 2>$null

    git pull --ff-only 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "git pull failed — trying reset to origin/$branch"
        git fetch origin
        git reset --hard "origin/$branch"
    }

    $afterHash = git rev-parse HEAD 2>$null
    Pop-Location

    if ($beforeHash -eq $afterHash) {
        Write-OK "Already up to date ($($afterHash.Substring(0,7)))"
    } else {
        Write-OK "Updated: $($beforeHash.Substring(0,7)) → $($afterHash.Substring(0,7))"
        # Show what changed
        Push-Location $REPO_DIR
        git log --oneline "$beforeHash..$afterHash" 2>$null | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
        Pop-Location
    }
    $SOURCE_DIR = $REPO_DIR
} else {
    # No git repo — use the script's own directory as source (manual update path)
    $SOURCE_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
    Write-Warn "No git repo found. Using local files from $SOURCE_DIR"
}

# -----------------------------------------------------------
# 3. Copy updated files
# -----------------------------------------------------------
Write-Host ""
Write-Host "--- Deploying files ---"

$files = @("server.py", "context.md", "requirements.txt")
foreach ($f in $files) {
    $src = Join-Path $SOURCE_DIR $f
    if (Test-Path $src) {
        $dst = Join-Path $INSTALL_DIR $f
        $srcHash = (Get-FileHash $src -Algorithm MD5).Hash
        $dstHash = if (Test-Path $dst) { (Get-FileHash $dst -Algorithm MD5).Hash } else { "" }
        if ($srcHash -ne $dstHash) {
            Copy-Item $src $dst -Force
            Write-OK "$f updated"
        } else {
            Write-Host "  $f unchanged" -ForegroundColor DarkGray
        }
    }
}

# -----------------------------------------------------------
# 4. Update venv packages if requirements changed
# -----------------------------------------------------------
$VENV_PYTHON = "$INSTALL_DIR\.venv\Scripts\python.exe"
if (Test-Path $VENV_PYTHON) {
    Write-Host ""
    Write-Host "--- Checking Python packages ---"
    & $VENV_PYTHON -m pip install --quiet -r "$INSTALL_DIR\requirements.txt" 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-OK "Packages up to date"
    } else {
        Write-Warn "pip install had warnings — run install-windows.ps1 if imports fail"
    }
} else {
    Write-Warn "Venv not found at $VENV_PYTHON — run install-windows.ps1 to recreate"
}

# -----------------------------------------------------------
# 5. Write version stamp
# -----------------------------------------------------------
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$gitHash = if (Test-Path "$REPO_DIR\.git") {
    Push-Location $REPO_DIR; $h = git rev-parse --short HEAD 2>$null; Pop-Location; $h
} else { "no-git" }
"updated=$timestamp`ngit=$gitHash`nsource=$SOURCE_DIR" | Set-Content "$INSTALL_DIR\version.txt" -Encoding UTF8

# -----------------------------------------------------------
# Done
# -----------------------------------------------------------
Write-Host ""
Write-Host "=========================================" -ForegroundColor Green
Write-Host "  Update complete!" -ForegroundColor Green
Write-Host "=========================================" -ForegroundColor Green
Write-Host ""
Write-Host "No need to restart Claude Desktop — changes take effect on the next query."
Write-Host ""

Read-Host "Press Enter to exit"
