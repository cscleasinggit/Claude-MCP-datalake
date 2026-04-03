# ============================================================
# CSC MCP Server — Reconnect to Azure
# Double-click this file or run from PowerShell to refresh
# your Azure login when queries stop working.
# ============================================================

Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "  CSC MCP Server — Azure Reconnect"      -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""

# Check if Azure CLI is available
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Host "[FAIL] Azure CLI not found. Run install-windows.ps1 first." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

# Check if we already have a valid token
Write-Host "Checking current Azure session..."
$tokenCheck = az account get-access-token --resource https://database.windows.net/ 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "[OK] You're already connected! Token is valid." -ForegroundColor Green
    Write-Host ""
    Write-Host "If queries are still failing, the issue may be something else."
    Write-Host "Check server logs at: %APPDATA%\Claude\logs\mcp*.log"
} else {
    Write-Host "Token expired or missing. Opening browser for login..."
    Write-Host ""
    az login
    if ($LASTEXITCODE -eq 0) {
        Write-Host ""
        Write-Host "[OK] Connected! Claude can query the database again." -ForegroundColor Green
        Write-Host ""
        Write-Host "No need to restart Claude — just try your query again."
    } else {
        Write-Host ""
        Write-Host "[FAIL] Login failed. Try again or contact Hunter." -ForegroundColor Red
    }
}

Write-Host ""
Read-Host "Press Enter to close"
