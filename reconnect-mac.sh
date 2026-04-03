#!/bin/bash
# ============================================================
# CSC MCP Server — Reconnect to Azure (Mac)
# Double-click or run from Terminal to refresh Azure login
# when queries stop working.
# ============================================================

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

echo ""
echo -e "${CYAN}=========================================${NC}"
echo -e "${CYAN}  CSC MCP Server — Azure Reconnect${NC}"
echo -e "${CYAN}=========================================${NC}"
echo ""

# Check if Azure CLI is available
if ! command -v az &>/dev/null; then
    echo -e "${RED}[FAIL]${NC} Azure CLI not found. Run install-mac.sh first."
    exit 1
fi

# Check if we already have a valid token
echo "Checking current Azure session..."
if az account get-access-token --resource https://database.windows.net/ &>/dev/null; then
    echo ""
    echo -e "${GREEN}[OK] You're already connected! Token is valid.${NC}"
    echo ""
    echo "If queries are still failing, the issue may be something else."
    echo "Check server logs at: ~/Library/Logs/Claude/mcp*.log"
else
    echo "Token expired or missing. Opening browser for login..."
    echo ""
    if az login; then
        echo ""
        echo -e "${GREEN}[OK] Connected! Claude can query the database again.${NC}"
        echo ""
        echo "No need to restart Claude — just try your query again."
    else
        echo ""
        echo -e "${RED}[FAIL] Login failed. Try again or contact Hunter.${NC}"
    fi
fi

echo ""
