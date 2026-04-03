#!/bin/bash
# ============================================================
# CSC Leasing SQL MCP Server — Update Script (Mac)
# Pulls latest server files from git and redeploys.
# Run: ./update-mac.sh
# ============================================================

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
GRAY='\033[0;37m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

INSTALL_DIR="$HOME/csc-mcp-server"
REPO_DIR="$INSTALL_DIR/.repo"

echo ""
echo -e "${CYAN}=========================================${NC}"
echo -e "${CYAN}  CSC MCP Server — Update${NC}"
echo -e "${CYAN}=========================================${NC}"
echo ""

# Verify install exists
[ -f "$INSTALL_DIR/server.py" ] || fail "No existing install found at $INSTALL_DIR. Run install-mac.sh first."

# Pull latest from git (if repo exists)
if [ -d "$REPO_DIR/.git" ]; then
    echo "--- Pulling latest from git ---"
    cd "$REPO_DIR"
    BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    BEFORE=$(git rev-parse HEAD 2>/dev/null)

    git pull --ff-only 2>/dev/null || {
        warn "git pull failed — trying reset to origin/$BRANCH"
        git fetch origin
        git reset --hard "origin/$BRANCH"
    }

    AFTER=$(git rev-parse HEAD 2>/dev/null)

    if [ "$BEFORE" = "$AFTER" ]; then
        ok "Already up to date (${AFTER:0:7})"
    else
        ok "Updated: ${BEFORE:0:7} → ${AFTER:0:7}"
        git log --oneline "$BEFORE..$AFTER" 2>/dev/null | while read -r line; do
            echo -e "  ${GRAY}$line${NC}"
        done
    fi
    SOURCE_DIR="$REPO_DIR"
else
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    SOURCE_DIR="$SCRIPT_DIR"
    warn "No git repo found. Using local files from $SOURCE_DIR"
fi

# Copy updated files
echo ""
echo "--- Deploying files ---"
for f in server.py context.md requirements.txt; do
    SRC="$SOURCE_DIR/$f"
    DST="$INSTALL_DIR/$f"
    if [ -f "$SRC" ]; then
        if [ -f "$DST" ] && cmp -s "$SRC" "$DST"; then
            echo -e "  ${GRAY}$f unchanged${NC}"
        else
            cp "$SRC" "$DST"
            ok "$f updated"
        fi
    fi
done

# Update venv packages if requirements changed
VENV_PYTHON="$INSTALL_DIR/.venv/bin/python3"
if [ -f "$VENV_PYTHON" ]; then
    echo ""
    echo "--- Checking Python packages ---"
    "$VENV_PYTHON" -m pip install --quiet -r "$INSTALL_DIR/requirements.txt" 2>/dev/null \
        && ok "Packages up to date" \
        || warn "pip install had warnings — run install-mac.sh if imports fail"
else
    warn "Venv not found — run install-mac.sh to recreate"
fi

# Write version stamp
GIT_HASH="no-git"
[ -d "$REPO_DIR/.git" ] && GIT_HASH=$(cd "$REPO_DIR" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
cat > "$INSTALL_DIR/version.txt" <<EOF
updated=$(date '+%Y-%m-%d %H:%M:%S')
git=$GIT_HASH
source=$SOURCE_DIR
EOF

echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}  Update complete!${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""
echo "No need to restart Claude Desktop — changes take effect on the next query."
echo ""
