#!/bin/bash
# ============================================================
# CSC Leasing SQL MCP Server — Mac Setup Script
# Run: chmod +x install-mac.sh && ./install-mac.sh
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

INSTALL_DIR="$HOME/csc-mcp-server"
REPO_URL="https://github.com/cscleasinggit/Claude-MCP-datalake.git"
REPO_DIR="$INSTALL_DIR/.repo"

# Detect Claude Desktop config path (Mac App Store vs direct install)
CLAUDE_CONFIG_STORE=$(find "$HOME/Library/Containers" -path "*/Claude/Data/Library/Application Support/Claude" -maxdepth 5 2>/dev/null | head -1)
CLAUDE_CONFIG_DIRECT="$HOME/Library/Application Support/Claude"

if [ -n "$CLAUDE_CONFIG_STORE" ]; then
    CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_STORE"
    ok "Detected Claude Desktop (Mac App Store) at $CLAUDE_CONFIG_DIR"
elif [ -d "$CLAUDE_CONFIG_DIRECT" ]; then
    CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIRECT"
    ok "Detected Claude Desktop (direct install) at $CLAUDE_CONFIG_DIR"
else
    mkdir -p "$CLAUDE_CONFIG_DIRECT"
    CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIRECT"
    warn "No Claude config found — creating at $CLAUDE_CONFIG_DIR"
fi

CLAUDE_CONFIG="$CLAUDE_CONFIG_DIR/claude_desktop_config.json"

echo ""
echo -e "${CYAN}=========================================${NC}"
echo -e "${CYAN}  CSC Leasing SQL — MCP Server Setup${NC}"
echo -e "${CYAN}=========================================${NC}"
echo ""

# -----------------------------------------------------------
# 1. Check / install Homebrew
# -----------------------------------------------------------
echo "--- Step 1: Homebrew ---"
if command -v brew &>/dev/null; then
    ok "Homebrew installed"
else
    warn "Homebrew not found. Installing..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # Add to path for Apple Silicon
    if [ -f /opt/homebrew/bin/brew ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
    ok "Homebrew installed"
fi

# -----------------------------------------------------------
# 2. Check / install Python 3
# -----------------------------------------------------------
echo ""
echo "--- Step 2: Python ---"
if command -v python3 &>/dev/null; then
    PYTHON=$(command -v python3)
    ok "Python found: $PYTHON ($(python3 --version))"
    "$PYTHON" -c "import sys; exit(0 if sys.version_info >= (3, 10) else 1)" 2>/dev/null \
        || fail "Python 3.10+ required. Found: $($PYTHON --version). Install: brew install python"
else
    warn "Python 3 not found. Installing via Homebrew..."
    brew install python
    PYTHON=$(command -v python3)
    ok "Python installed: $PYTHON"
fi

# -----------------------------------------------------------
# 3. Check / install ODBC Driver 18 for SQL Server
# -----------------------------------------------------------
echo ""
echo "--- Step 3: ODBC Driver 18 ---"
if odbcinst -q -d 2>/dev/null | grep -q "ODBC Driver 18"; then
    ok "ODBC Driver 18 for SQL Server installed"
else
    warn "ODBC Driver 18 not found. Installing via Homebrew..."
    brew tap microsoft/mssql-release https://github.com/Microsoft/homebrew-mssql-release
    brew update
    HOMEBREW_ACCEPT_EULA=Y brew install msodbcsql18
    ok "ODBC Driver 18 installed"
fi

# -----------------------------------------------------------
# 4. Check / install Azure CLI
# -----------------------------------------------------------
echo ""
echo "--- Step 4: Azure CLI ---"
if command -v az &>/dev/null; then
    ok "Azure CLI installed ($(az --version 2>/dev/null | head -1))"
else
    warn "Azure CLI not found. Installing via Homebrew..."
    brew install azure-cli
    ok "Azure CLI installed"
fi

# -----------------------------------------------------------
# 5. Copy server files (+ optional git clone for auto-updates)
# -----------------------------------------------------------
echo ""
echo "--- Step 5: Server files ---"
mkdir -p "$INSTALL_DIR"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
USE_GIT=false

# Try to clone/update git repo for auto-updates
if command -v git &>/dev/null; then
    if [ -d "$REPO_DIR/.git" ]; then
        echo "  Updating existing repo..."
        (cd "$REPO_DIR" && git pull --ff-only 2>/dev/null) && { ok "Git repo updated"; USE_GIT=true; } \
            || warn "Git pull failed — using local files"
    else
        echo "  Attempting git clone for auto-updates..."
        git clone "$REPO_URL" "$REPO_DIR" 2>/dev/null && { ok "Repo cloned — future updates via update-mac.sh"; USE_GIT=true; } \
            || warn "Git clone failed (repo may not exist yet) — using local files"
    fi
fi

# Determine source: git repo or script's folder
if $USE_GIT && [ -f "$REPO_DIR/server.py" ]; then
    SOURCE_DIR="$REPO_DIR"
    ok "Using git repo as source: $SOURCE_DIR"
else
    SOURCE_DIR="$SCRIPT_DIR"
fi

if [ -f "$SOURCE_DIR/server.py" ]; then
    cp "$SOURCE_DIR/server.py" "$INSTALL_DIR/server.py"
    ok "server.py copied to $INSTALL_DIR"
else
    fail "server.py not found in $SOURCE_DIR — run this script from the csc-mcp-server folder"
fi

if [ -f "$SOURCE_DIR/context.md" ]; then
    cp "$SOURCE_DIR/context.md" "$INSTALL_DIR/context.md"
    ok "context.md copied to $INSTALL_DIR"
else
    warn "context.md not found — get_context tool will not have domain knowledge"
fi

[ -f "$SOURCE_DIR/requirements.txt" ] && cp "$SOURCE_DIR/requirements.txt" "$INSTALL_DIR/requirements.txt"

# Copy helper scripts
for script in update-mac.sh reconnect-mac.sh; do
    [ -f "$SOURCE_DIR/$script" ] && cp "$SOURCE_DIR/$script" "$INSTALL_DIR/$script" && chmod +x "$INSTALL_DIR/$script"
done

# Write version stamp
GIT_HASH="no-git"
if $USE_GIT; then
    GIT_HASH=$(cd "$REPO_DIR" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
fi
cat > "$INSTALL_DIR/version.txt" <<EOF
installed=$(date '+%Y-%m-%d %H:%M:%S')
git=$GIT_HASH
source=$SOURCE_DIR
EOF
ok "Version stamp written"

# -----------------------------------------------------------
# 6. Create venv & install Python dependencies
# -----------------------------------------------------------
echo ""
echo "--- Step 6: Python venv & packages ---"
VENV_DIR="$INSTALL_DIR/.venv"
VENV_PYTHON="$VENV_DIR/bin/python3"

if [ ! -f "$VENV_PYTHON" ]; then
    echo "  Creating virtual environment..."
    "$PYTHON" -m venv "$VENV_DIR" || fail "Failed to create venv at $VENV_DIR"
    ok "Virtual environment created at $VENV_DIR"
else
    ok "Virtual environment already exists"
fi

"$VENV_PYTHON" -m pip install --quiet --upgrade pip 2>/dev/null
"$VENV_PYTHON" -m pip install --quiet pyodbc azure-identity \
    || fail "pip install failed — check network and try again"
ok "pyodbc and azure-identity installed in venv"

# Verify imports
"$VENV_PYTHON" -c "import pyodbc; from azure.identity import DefaultAzureCredential; print('OK')" 2>/dev/null \
    && ok "Imports verified" \
    || fail "Python package import failed"

# -----------------------------------------------------------
# 7. Azure login
# -----------------------------------------------------------
echo ""
echo "--- Step 7: Azure login ---"
if az account get-access-token --resource https://database.windows.net/ &>/dev/null; then
    ok "Azure token valid"
else
    warn "No valid Azure session. Opening browser login..."
    az login || fail "Azure login failed"
    ok "Azure login complete"
fi

# -----------------------------------------------------------
# 8. Test database connection
# -----------------------------------------------------------
echo ""
echo "--- Step 8: Database connection test ---"
TEST_RESULT=$("$VENV_PYTHON" -c "
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
" 2>&1) && ok "Database connection successful ($TEST_RESULT Opportunity records)" \
          || fail "Database connection failed. Check Azure permissions on lw_csc. Error: $TEST_RESULT"

# -----------------------------------------------------------
# 9. Configure Claude Desktop
# -----------------------------------------------------------
echo ""
echo "--- Step 9: Claude Desktop config ---"
VENV_PYTHON_ABS="$(cd "$(dirname "$VENV_PYTHON")" && pwd)/$(basename "$VENV_PYTHON")"

if [ -f "$CLAUDE_CONFIG" ]; then
    # Back up existing config
    BACKUP="$CLAUDE_CONFIG.bak.$(date '+%Y%m%d_%H%M%S')"
    cp "$CLAUDE_CONFIG" "$BACKUP"
    ok "Backed up existing config to $BACKUP"

    if grep -q '"csc-sql"' "$CLAUDE_CONFIG" 2>/dev/null; then
        # Update existing entry
        "$VENV_PYTHON" -c "
import json
with open('$CLAUDE_CONFIG', 'r') as f:
    config = json.load(f)
config['mcpServers']['csc-sql'] = {
    'command': '$VENV_PYTHON_ABS',
    'args': ['$INSTALL_DIR/server.py'],
    'env': {'AZURE_CONFIG_DIR': '$HOME/.azure'}
}
with open('$CLAUDE_CONFIG', 'w') as f:
    json.dump(config, f, indent=2)
" && ok "Updated csc-sql paths in Claude config"
    else
        "$VENV_PYTHON" -c "
import json
with open('$CLAUDE_CONFIG', 'r') as f:
    config = json.load(f)
if 'mcpServers' not in config:
    config['mcpServers'] = {}
config['mcpServers']['csc-sql'] = {
    'command': '$VENV_PYTHON_ABS',
    'args': ['$INSTALL_DIR/server.py'],
    'env': {'AZURE_CONFIG_DIR': '$HOME/.azure'}
}
with open('$CLAUDE_CONFIG', 'w') as f:
    json.dump(config, f, indent=2)
" && ok "Added csc-sql to existing Claude config"
    fi
else
    "$VENV_PYTHON" -c "
import json
config = {
    'mcpServers': {
        'csc-sql': {
            'command': '$VENV_PYTHON_ABS',
            'args': ['$INSTALL_DIR/server.py'],
            'env': {'AZURE_CONFIG_DIR': '$HOME/.azure'}
        }
    }
}
with open('$CLAUDE_CONFIG', 'w') as f:
    json.dump(config, f, indent=2)
" && ok "Created Claude Desktop config"
fi

# -----------------------------------------------------------
# Done
# -----------------------------------------------------------
echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}  Setup complete!${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""
echo "Install directory:  $INSTALL_DIR"
echo "Venv Python:        $VENV_PYTHON_ABS"
echo "Claude config:      $CLAUDE_CONFIG"
echo ""
echo "Next steps:"
echo "  1. Quit Claude Desktop completely (Cmd+Q)"
echo "  2. Reopen Claude Desktop"
echo "  3. Go to Settings → Developer — verify 'csc-sql' shows as 'running'"
echo "  4. Start a new chat and ask: 'How many records are in the Opportunity table?'"
echo ""
echo "Updates:"
if $USE_GIT; then
    echo "  Git repo cloned. Run update-mac.sh to pull latest changes"
    echo "    or:  cd $INSTALL_DIR && ./update-mac.sh"
else
    echo "  No git repo. Re-run this script with updated files to update"
    echo "  Or install git and re-run — it will clone the repo for auto-updates"
fi
echo ""
echo "Troubleshooting:"
echo "  - Azure token expires every ~1 hour. Run: ./reconnect-mac.sh (or: az login)"
echo "  - Server logs: ~/Library/Logs/Claude/mcp*.log"
echo "  - Re-run this script to update server files without losing config"
echo ""
