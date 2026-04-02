#!/bin/bash
# ============================================================
# CSC Leasing SQL MCP Server — Mac Setup Script
# Run: chmod +x install-mac.sh && ./install-mac.sh
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

INSTALL_DIR="$HOME/csc-mcp-server"

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
    # Create the direct path as fallback
    mkdir -p "$CLAUDE_CONFIG_DIRECT"
    CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIRECT"
    warn "No Claude config found — creating at $CLAUDE_CONFIG_DIR"
fi

CLAUDE_CONFIG="$CLAUDE_CONFIG_DIR/claude_desktop_config.json"

echo ""
echo "========================================="
echo "  CSC Leasing SQL — MCP Server Setup"
echo "========================================="
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
    # Verify minimum version 3.10
    "$PYTHON" -c "import sys; exit(0 if sys.version_info >= (3, 10) else 1)" 2>/dev/null \
        || fail "Python 3.10+ required. Found: $($PYTHON --version). Install a newer version: brew install python"
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
# 5. Copy server files
# -----------------------------------------------------------
echo ""
echo "--- Step 5: Server files ---"
mkdir -p "$INSTALL_DIR"

# Copy server.py from same directory as this script
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/server.py" ]; then
    cp "$SCRIPT_DIR/server.py" "$INSTALL_DIR/server.py"
    ok "server.py copied to $INSTALL_DIR"
else
    fail "server.py not found in $SCRIPT_DIR — run this script from the csc-mcp-server folder"
fi

if [ -f "$SCRIPT_DIR/context.md" ]; then
    cp "$SCRIPT_DIR/context.md" "$INSTALL_DIR/context.md"
    ok "context.md copied to $INSTALL_DIR"
else
    warn "context.md not found — get_context tool will not have domain knowledge"
fi

# Write version stamp
echo "installed=$(date '+%Y-%m-%d %H:%M:%S')" > "$INSTALL_DIR/version.txt"
echo "script_dir=$SCRIPT_DIR" >> "$INSTALL_DIR/version.txt"
ok "Version stamp written to $INSTALL_DIR/version.txt"

# -----------------------------------------------------------
# 6. Install Python dependencies
# -----------------------------------------------------------
echo ""
echo "--- Step 6: Python packages ---"
if "$PYTHON" -m pip install --quiet pyodbc azure-identity 2>/dev/null; then
    ok "pyodbc and azure-identity installed"
else
    warn "Standard pip failed (externally-managed-environment). Retrying with --break-system-packages..."
    "$PYTHON" -m pip install --quiet --break-system-packages pyodbc azure-identity \
        || fail "pip install failed. Try: $PYTHON -m pip install --user pyodbc azure-identity"
    ok "pyodbc and azure-identity installed (--break-system-packages)"
fi

# Verify imports
"$PYTHON" -c "import pyodbc; from azure.identity import DefaultAzureCredential; print('OK')" 2>/dev/null \
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
    warn "No valid Azure session. Logging in..."
    az login
    ok "Azure login complete"
fi

# -----------------------------------------------------------
# 8. Test database connection
# -----------------------------------------------------------
echo ""
echo "--- Step 8: Database connection test ---"
"$PYTHON" -c "
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
" && ok "Database connection successful" \
  || fail "Database connection failed. Check your Azure permissions on lw_csc."

# -----------------------------------------------------------
# 9. Configure Claude Desktop
# -----------------------------------------------------------
echo ""
echo "--- Step 9: Claude Desktop config ---"
PYTHON_PATH="$PYTHON"
SERVER_PATH="$INSTALL_DIR/server.py"

if [ -f "$CLAUDE_CONFIG" ]; then
    # Check if csc-sql already exists in config
    if grep -q '"csc-sql"' "$CLAUDE_CONFIG" 2>/dev/null; then
        warn "csc-sql already in config — skipping (edit manually if needed)"
    else
        # Merge into existing config using Python
        "$PYTHON" -c "
import json
with open('$CLAUDE_CONFIG', 'r') as f:
    config = json.load(f)
if 'mcpServers' not in config:
    config['mcpServers'] = {}
config['mcpServers']['csc-sql'] = {
    'command': '$PYTHON_PATH',
    'args': ['$SERVER_PATH'],
    'env': {'AZURE_CONFIG_DIR': '$HOME/.azure'}
}
with open('$CLAUDE_CONFIG', 'w') as f:
    json.dump(config, f, indent=2)
print('OK')
" && ok "Added csc-sql to existing Claude config"
    fi
else
    # Create new config
    "$PYTHON" -c "
import json
config = {
    'mcpServers': {
        'csc-sql': {
            'command': '$PYTHON_PATH',
            'args': ['$SERVER_PATH'],
            'env': {'AZURE_CONFIG_DIR': '$HOME/.azure'}
        }
    }
}
with open('$CLAUDE_CONFIG', 'w') as f:
    json.dump(config, f, indent=2)
print('OK')
" && ok "Created Claude Desktop config"
fi

# -----------------------------------------------------------
# Done
# -----------------------------------------------------------
echo ""
echo "========================================="
echo -e "  ${GREEN}Setup complete!${NC}"
echo "========================================="
echo ""
echo "Next steps:"
echo "  1. Quit Claude Desktop completely (Cmd+Q)"
echo "  2. Reopen Claude Desktop"
echo "  3. Go to Settings → Developer — verify 'csc-sql' shows as 'running'"
echo "  4. Start a new chat and ask: 'How many records are in the Opportunity table?'"
echo ""
echo "If the Azure token expires, run:  az login"
echo ""
