# ============================================================
# CSC Leasing SQL MCP Server — Windows Setup Script
# Run: Right-click → Run with PowerShell
#   or: powershell -ExecutionPolicy Bypass -File install-windows.ps1
# ============================================================

$ErrorActionPreference = "Stop"

function Write-OK($msg)   { Write-Host "[OK]   $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "[!]    $msg" -ForegroundColor Yellow }
function Write-Fail($msg) { Write-Host "[FAIL] $msg" -ForegroundColor Red; exit 1 }

$INSTALL_DIR = "$env:USERPROFILE\csc-mcp-server"

# Detect Claude Desktop config path (Windows Store vs direct install)
$CLAUDE_CONFIG_STORE = Get-ChildItem "$env:LOCALAPPDATA\Packages\Claude_*\LocalCache\Roaming\Claude" -ErrorAction SilentlyContinue | Select-Object -First 1
$CLAUDE_CONFIG_ROAMING = "$env:APPDATA\Claude"

if ($CLAUDE_CONFIG_STORE) {
    $CLAUDE_CONFIG_DIR = $CLAUDE_CONFIG_STORE.FullName
    Write-OK "Detected Claude Desktop (Windows Store) at $CLAUDE_CONFIG_DIR"
} elseif (Test-Path $CLAUDE_CONFIG_ROAMING) {
    $CLAUDE_CONFIG_DIR = $CLAUDE_CONFIG_ROAMING
    Write-OK "Detected Claude Desktop (direct install) at $CLAUDE_CONFIG_DIR"
} else {
    # Create the Roaming path as fallback
    New-Item -ItemType Directory -Path $CLAUDE_CONFIG_ROAMING -Force | Out-Null
    $CLAUDE_CONFIG_DIR = $CLAUDE_CONFIG_ROAMING
    Write-Warn "No Claude config found — creating at $CLAUDE_CONFIG_DIR"
}

$CLAUDE_CONFIG = Join-Path $CLAUDE_CONFIG_DIR "claude_desktop_config.json"

Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "  CSC Leasing SQL — MCP Server Setup"     -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""

# -----------------------------------------------------------
# 1. Check / install Python
# -----------------------------------------------------------
Write-Host "--- Step 1: Python ---"
$PYTHON = $null

# Check common Python locations
$pythonCandidates = @(
    (Get-Command python3 -ErrorAction SilentlyContinue),
    (Get-Command python -ErrorAction SilentlyContinue)
) | Where-Object { $_ -ne $null }

foreach ($candidate in $pythonCandidates) {
    $path = $candidate.Source
    # Skip WindowsApps stub (it just opens the Store)
    if ($path -notlike "*WindowsApps*") {
        $PYTHON = $path
        break
    }
}

if ($PYTHON) {
    $pyVersion = & $PYTHON --version 2>&1
    Write-OK "Python found: $PYTHON ($pyVersion)"
    # Verify minimum version 3.10
    $verCheck = & $PYTHON -c "import sys; exit(0 if sys.version_info >= (3, 10) else 1)" 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Python 3.10+ required. Found: $pyVersion. Install a newer version from https://python.org"
    }
} else {
    Write-Warn "Python not found. Installing via winget..."
    winget install Python.Python.3.12 --accept-package-agreements --accept-source-agreements
    # Refresh PATH
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
    $PYTHON = (Get-Command python -ErrorAction SilentlyContinue).Source
    if (-not $PYTHON) { Write-Fail "Python install failed. Install manually from https://python.org" }
    Write-OK "Python installed: $PYTHON"
}

# -----------------------------------------------------------
# 2. Check / install ODBC Driver 18
# -----------------------------------------------------------
Write-Host ""
Write-Host "--- Step 2: ODBC Driver 18 ---"
$odbcDrivers = & $PYTHON -c "import pyodbc; print([d for d in pyodbc.drivers() if 'SQL Server' in d])" 2>$null
if ($LASTEXITCODE -ne 0) {
    # pyodbc not installed yet — check registry directly
    $odbcReg = Get-ItemProperty "HKLM:\SOFTWARE\ODBC\ODBCINST.INI\ODBC Driver 18 for SQL Server" -ErrorAction SilentlyContinue
    if ($odbcReg) {
        Write-OK "ODBC Driver 18 found (registry check)"
    } else {
        Write-Warn "ODBC Driver 18 not found. Installing via winget..."
        winget install Microsoft.msodbcsql18 --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "winget failed — download manually from https://go.microsoft.com/fwlink/?linkid=2266337"
            Write-Fail "ODBC Driver 18 install required"
        }
        Write-OK "ODBC Driver 18 installed"
    }
} elseif ($odbcDrivers -like "*ODBC Driver 18*") {
    Write-OK "ODBC Driver 18 detected via pyodbc"
} else {
    Write-Warn "ODBC Driver 18 not found. Installing via winget..."
    winget install Microsoft.msodbcsql18 --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "winget failed — download manually from https://go.microsoft.com/fwlink/?linkid=2266337"
        Write-Fail "ODBC Driver 18 install required"
    }
    Write-OK "ODBC Driver 18 installed"
}

# -----------------------------------------------------------
# 3. Check / install Azure CLI
# -----------------------------------------------------------
Write-Host ""
Write-Host "--- Step 3: Azure CLI ---"
if (Get-Command az -ErrorAction SilentlyContinue) {
    $azVersion = (az --version 2>$null | Select-Object -First 1)
    Write-OK "Azure CLI installed ($azVersion)"
} else {
    Write-Warn "Azure CLI not found. Installing via winget..."
    winget install Microsoft.AzureCLI --accept-package-agreements --accept-source-agreements
    # Refresh PATH
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        Write-Fail "Azure CLI install failed. Install manually from https://aka.ms/installazurecliwindows"
    }
    Write-OK "Azure CLI installed"
}

# -----------------------------------------------------------
# 4. Copy server files (+ optional git clone for auto-updates)
# -----------------------------------------------------------
Write-Host ""
Write-Host "--- Step 4: Server files ---"
New-Item -ItemType Directory -Path $INSTALL_DIR -Force | Out-Null

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$REPO_DIR = "$INSTALL_DIR\.repo"
$REPO_URL = "https://github.com/cscleasinggit/Claude-MCP-datalake.git"

# Try to clone/update git repo for auto-updates
$useGit = $false
if (Get-Command git -ErrorAction SilentlyContinue) {
    if (Test-Path "$REPO_DIR\.git") {
        Write-Host "  Updating existing repo..."
        Push-Location $REPO_DIR
        git pull --ff-only 2>$null
        Pop-Location
        if ($LASTEXITCODE -eq 0) {
            Write-OK "Git repo updated"
            $useGit = $true
        } else {
            Write-Warn "Git pull failed — using local files"
        }
    } else {
        Write-Host "  Attempting git clone for auto-updates..."
        git clone $REPO_URL $REPO_DIR 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-OK "Repo cloned — future updates via update-windows.ps1"
            $useGit = $true
        } else {
            Write-Warn "Git clone failed (repo may not exist yet) — using local files"
        }
    }
}

# Determine source directory: git repo if available, else script's folder
if ($useGit -and (Test-Path "$REPO_DIR\server.py")) {
    $SOURCE_DIR = $REPO_DIR
    Write-OK "Using git repo as source: $SOURCE_DIR"
} else {
    $SOURCE_DIR = $scriptDir
    if ($useGit) { Write-Warn "Git repo structure not recognized — falling back to local files" }
}

$serverSource = Join-Path $SOURCE_DIR "server.py"

if (Test-Path $serverSource) {
    Copy-Item $serverSource "$INSTALL_DIR\server.py" -Force
    Write-OK "server.py copied to $INSTALL_DIR"
} else {
    Write-Fail "server.py not found in $SOURCE_DIR — run this script from the csc-mcp-server folder"
}

$contextSource = Join-Path $SOURCE_DIR "context.md"
if (Test-Path $contextSource) {
    Copy-Item $contextSource "$INSTALL_DIR\context.md" -Force
    Write-OK "context.md copied to $INSTALL_DIR"
} else {
    Write-Warn "context.md not found — get_context tool will not have domain knowledge"
}

$reqSource = Join-Path $SOURCE_DIR "requirements.txt"
if (Test-Path $reqSource) {
    Copy-Item $reqSource "$INSTALL_DIR\requirements.txt" -Force
}

# Copy update script if present
$updateSource = Join-Path $SOURCE_DIR "update-windows.ps1"
if (Test-Path $updateSource) {
    Copy-Item $updateSource "$INSTALL_DIR\update-windows.ps1" -Force
    Write-OK "update-windows.ps1 copied (run this to pull future updates)"
}

# Write version stamp
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$gitHash = if (Test-Path "$REPO_DIR\.git") {
    Push-Location $REPO_DIR; $h = git rev-parse --short HEAD 2>$null; Pop-Location; $h
} else { "no-git" }
"installed=$timestamp`ngit=$gitHash`nsource=$SOURCE_DIR" | Set-Content "$INSTALL_DIR\version.txt" -Encoding UTF8
Write-OK "Version stamp written"

# -----------------------------------------------------------
# 5. Create venv & install Python dependencies
# -----------------------------------------------------------
Write-Host ""
Write-Host "--- Step 5: Python venv & packages ---"
$VENV_DIR = "$INSTALL_DIR\.venv"
$VENV_PYTHON = "$VENV_DIR\Scripts\python.exe"

if (-not (Test-Path $VENV_PYTHON)) {
    Write-Host "  Creating virtual environment..."
    & $PYTHON -m venv $VENV_DIR
    if ($LASTEXITCODE -ne 0) { Write-Fail "Failed to create venv at $VENV_DIR" }
    Write-OK "Virtual environment created at $VENV_DIR"
} else {
    Write-OK "Virtual environment already exists"
}

# Install into venv
& $VENV_PYTHON -m pip install --quiet --upgrade pip 2>$null
& $VENV_PYTHON -m pip install --quiet pyodbc azure-identity
if ($LASTEXITCODE -ne 0) {
    Write-Fail "pip install failed — check network and try again"
}
Write-OK "pyodbc and azure-identity installed in venv"

# Verify imports
& $VENV_PYTHON -c "import pyodbc; from azure.identity import DefaultAzureCredential; print('OK')" 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "Python package import failed" }
Write-OK "Imports verified"

# -----------------------------------------------------------
# 6. Azure login
# -----------------------------------------------------------
Write-Host ""
Write-Host "--- Step 6: Azure login ---"
$tokenCheck = az account get-access-token --resource https://database.windows.net/ 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-OK "Azure token valid"
} else {
    Write-Warn "No valid Azure session. Opening browser login..."
    az login
    if ($LASTEXITCODE -ne 0) { Write-Fail "Azure login failed" }
    Write-OK "Azure login complete"
}

# -----------------------------------------------------------
# 7. Test database connection
# -----------------------------------------------------------
Write-Host ""
Write-Host "--- Step 7: Database connection test ---"
$testResult = & $VENV_PYTHON -c @"
import struct, pyodbc
from azure.identity import DefaultAzureCredential
cred = DefaultAzureCredential()
tok = cred.get_token('https://database.windows.net/.default')
tb = tok.token.encode('UTF-16-LE')
ts = struct.pack(f'<I{len(tb)}s', len(tb), tb)
conn = pyodbc.connect(
    'Driver={ODBC Driver 18 for SQL Server};'
    'Server=csc-leasing-analytics-sql01-prod.database.windows.net;'
    'Database=lw_csc;Encrypt=yes;TrustServerCertificate=no;',
    attrs_before={1256: ts}
)
cur = conn.cursor()
cur.execute('SELECT COUNT(*) FROM sf.Opportunity')
print(cur.fetchone()[0])
conn.close()
"@ 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-OK "Database connection successful ($testResult Opportunity records)"
} else {
    Write-Fail "Database connection failed. Check Azure permissions on lw_csc. Error: $testResult"
}

# -----------------------------------------------------------
# 8. Configure Claude Desktop
# -----------------------------------------------------------
Write-Host ""
Write-Host "--- Step 8: Claude Desktop config ---"
$venvPythonAbs = (Resolve-Path $VENV_PYTHON).Path

if (Test-Path $CLAUDE_CONFIG) {
    # Back up existing config before modifying
    $backupPath = "$CLAUDE_CONFIG.bak.$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    Copy-Item $CLAUDE_CONFIG $backupPath
    Write-OK "Backed up existing config to $backupPath"

    $configContent = Get-Content $CLAUDE_CONFIG -Raw | ConvertFrom-Json

    if ($configContent.mcpServers.'csc-sql') {
        Write-Warn "csc-sql already in config — updating with current paths"
        $configContent.mcpServers.'csc-sql'.command = $venvPythonAbs
        $configContent.mcpServers.'csc-sql'.args = @("$INSTALL_DIR\server.py")
        $configContent.mcpServers.'csc-sql'.env = [PSCustomObject]@{
            AZURE_CONFIG_DIR = "$env:USERPROFILE\.azure"
        }
        $configContent | ConvertTo-Json -Depth 10 | Set-Content $CLAUDE_CONFIG -Encoding UTF8
        Write-OK "Updated csc-sql paths in Claude config"
    } else {
        # Add csc-sql to existing config
        if (-not $configContent.mcpServers) {
            $configContent | Add-Member -NotePropertyName "mcpServers" -NotePropertyValue ([PSCustomObject]@{})
        }
        $cscSql = [PSCustomObject]@{
            command = $venvPythonAbs
            args = @("$INSTALL_DIR\server.py")
            env = [PSCustomObject]@{
                AZURE_CONFIG_DIR = "$env:USERPROFILE\.azure"
            }
        }
        $configContent.mcpServers | Add-Member -NotePropertyName "csc-sql" -NotePropertyValue $cscSql
        $configContent | ConvertTo-Json -Depth 10 | Set-Content $CLAUDE_CONFIG -Encoding UTF8
        Write-OK "Added csc-sql to existing Claude config"
    }
} else {
    # Create new config
    $config = [PSCustomObject]@{
        mcpServers = [PSCustomObject]@{
            "csc-sql" = [PSCustomObject]@{
                command = $venvPythonAbs
                args = @("$INSTALL_DIR\server.py")
                env = [PSCustomObject]@{
                    AZURE_CONFIG_DIR = "$env:USERPROFILE\.azure"
                }
            }
        }
    }
    $config | ConvertTo-Json -Depth 10 | Set-Content $CLAUDE_CONFIG -Encoding UTF8
    Write-OK "Created Claude Desktop config at $CLAUDE_CONFIG"
}

# -----------------------------------------------------------
# Done
# -----------------------------------------------------------
Write-Host ""
Write-Host "=========================================" -ForegroundColor Green
Write-Host "  Setup complete!" -ForegroundColor Green
Write-Host "=========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Install directory:  $INSTALL_DIR"
Write-Host "Venv Python:       $venvPythonAbs"
Write-Host "Claude config:     $CLAUDE_CONFIG"
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Quit Claude Desktop completely (right-click system tray → Quit)"
Write-Host "  2. Reopen Claude Desktop"
Write-Host "  3. Go to Settings → Developer — verify 'csc-sql' shows as 'running'"
Write-Host "  4. Start a new chat and ask: 'How many records are in the Opportunity table?'"
Write-Host ""
Write-Host "Updates:"
if ($useGit) {
    Write-Host "  - Git repo cloned. Run update-windows.ps1 to pull latest changes"
    Write-Host "    or:  cd $INSTALL_DIR && powershell -File update-windows.ps1"
} else {
    Write-Host "  - No git repo. Re-run this script with updated files to update"
    Write-Host "  - Or install git and re-run — it will clone the repo for auto-updates"
}
Write-Host ""
Write-Host "Troubleshooting:"
Write-Host "  - Azure token expires every ~1 hour. If queries fail, run:  az login"
Write-Host "  - Server logs:  %APPDATA%\Claude\logs\mcp*.log"
Write-Host "  - Re-run this script to update server files without losing config"
Write-Host ""

Read-Host "Press Enter to exit"
