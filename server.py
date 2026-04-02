"""CSC Leasing Azure SQL MCP Server
Uses Azure CLI credentials (az login) for Entra ID authentication.
"""
import json
import sys
import os

# Log to stderr — Claude Desktop captures this in its MCP log
def log(msg):
    print(f"[csc-azure-sql] {msg}", file=sys.stderr, flush=True)

log("Server starting...")
log(f"Python: {sys.executable}")
log(f"CWD: {os.getcwd()}")

try:
    import pyodbc
    log(f"pyodbc loaded OK (version {pyodbc.version})")
except ImportError as e:
    log(f"FATAL: Cannot import pyodbc: {e}")
    log("Install with: pip install pyodbc")
    sys.exit(1)

try:
    import struct
    from azure.identity import DefaultAzureCredential
    log("azure-identity loaded OK")
except ImportError as e:
    log(f"FATAL: Cannot import azure-identity: {e}")
    log("Install with: pip install azure-identity")
    sys.exit(1)

# Use token-based auth — works with any ODBC driver version
CONNECTION_STRING = (
    "Driver={ODBC Driver 18 for SQL Server};"
    "Server=csc-leasing-analytics-sql01-prod.database.windows.net;"
    "Database=lw_csc;"
    "Encrypt=yes;"
    "TrustServerCertificate=no;"
    "Connection Timeout=30;"
)

# Safety limits
QUERY_TIMEOUT_SECONDS = 120   # Kill queries that run longer than 2 min
MAX_ROWS_HARD_LIMIT = 50000   # Absolute ceiling regardless of max_rows param

def get_token():
    """Get Azure AD token and pack it for pyodbc."""
    credential = DefaultAzureCredential()
    token = credential.get_token("https://database.windows.net/.default")
    token_bytes = token.token.encode("UTF-16-LE")
    token_struct = struct.pack(f"<I{len(token_bytes)}s", len(token_bytes), token_bytes)
    return token_struct

def get_connection():
    try:
        token = get_token()
    except Exception as e:
        error_msg = str(e)
        log(f"Token error: {error_msg}")
        if "AADSTS" in error_msg or "interactive" in error_msg.lower() or "credential" in error_msg.lower():
            raise ConnectionError(
                "Azure token expired or unavailable. Run 'az login' in a terminal to refresh."
            ) from e
        raise
    return pyodbc.connect(CONNECTION_STRING, attrs_before={1256: token})

def execute_query(sql, max_rows=5000):
    cleaned = sql.strip().upper()
    blocked = ["INSERT", "UPDATE", "DELETE", "DROP", "ALTER", "CREATE", "TRUNCATE", "EXEC", "EXECUTE"]
    first_keyword = cleaned.split()[0] if cleaned.split() else ""
    if first_keyword in blocked:
        return {"error": f"{first_keyword} statements are not allowed. Read-only access only."}

    # Enforce hard row limit
    effective_max = min(max_rows, MAX_ROWS_HARD_LIMIT)

    conn = get_connection()
    cursor = conn.cursor()
    cursor.execute(f"SET LOCK_TIMEOUT 5000")         # 5s lock wait
    cursor.execute(f"SET QUERY_GOVERNOR_COST_LIMIT 0")
    conn.timeout = QUERY_TIMEOUT_SECONDS
    try:
        cursor.execute(sql)
    except pyodbc.Error as e:
        conn.close()
        error_msg = str(e)
        if "timeout" in error_msg.lower() or "HYT00" in error_msg:
            return {"error": f"Query timed out after {QUERY_TIMEOUT_SECONDS}s. Simplify the query or add filters."}
        raise

    columns = [desc[0] for desc in cursor.description] if cursor.description else []
    rows = cursor.fetchmany(effective_max)
    result = [dict(zip(columns, [str(v) if v is not None else None for v in row])) for row in rows]

    total = len(result)
    if total == effective_max and effective_max < max_rows:
        note = f"(Showing first {effective_max} rows — hard limit reached. Add TOP or WHERE to narrow results)"
    elif total == effective_max:
        note = f"(Showing first {effective_max} rows — add TOP or WHERE to narrow results)"
    else:
        note = f"({total} rows returned)"

    conn.close()
    return {"columns": columns, "rows": result, "note": note}

def list_tables():
    conn = get_connection()
    cursor = conn.cursor()
    cursor.execute("""
        SELECT s.name AS schema_name, t.name AS table_name, p.rows AS row_count
        FROM sys.tables t
        INNER JOIN sys.schemas s ON t.schema_id = s.schema_id
        INNER JOIN sys.partitions p ON t.object_id = p.object_id AND p.index_id IN (0,1)
        ORDER BY s.name, t.name
    """)
    columns = [desc[0] for desc in cursor.description]
    rows = cursor.fetchall()
    result = [dict(zip(columns, [str(v) if v is not None else None for v in row])) for row in rows]
    conn.close()
    return result

def describe_table(table_name):
    conn = get_connection()
    cursor = conn.cursor()
    if "." in table_name:
        schema, table = table_name.split(".", 1)
    else:
        schema, table = "sf", table_name

    cursor.execute("""
        SELECT COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH, IS_NULLABLE
        FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?
        ORDER BY ORDINAL_POSITION
    """, schema, table)
    columns = [desc[0] for desc in cursor.description]
    rows = cursor.fetchall()
    result = [dict(zip(columns, [str(v) if v is not None else None for v in row])) for row in rows]
    conn.close()
    return result

def get_context():
    """Load the domain context file that ships alongside server.py."""
    context_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "context.md")
    try:
        with open(context_path, "r", encoding="utf-8") as f:
            return f.read()
    except FileNotFoundError:
        return "Context file not found. Expected at: " + context_path

# --- MCP Protocol over stdio ---

TOOLS = [
    {
        "name": "query",
        "description": "Execute a read-only SQL query against the CSC Azure SQL database. Use T-SQL syntax. Tables are in the 'sf' schema (e.g., sf.Opportunity, sf.Lease, sf.Asset). Default limit is 5000 rows.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "sql": {"type": "string", "description": "The T-SQL SELECT query to execute"},
                "max_rows": {"type": "integer", "description": "Max rows to return (default 5000). Use higher values for large exports.", "default": 5000}
            },
            "required": ["sql"]
        }
    },
    {
        "name": "list_tables",
        "description": "List all tables in the database with their schema and row counts.",
        "inputSchema": {
            "type": "object",
            "properties": {}
        }
    },
    {
        "name": "describe_table",
        "description": "Get column names and types for a table. Pass just the table name (e.g., 'Opportunity') or schema.table (e.g., 'sf.Opportunity').",
        "inputSchema": {
            "type": "object",
            "properties": {
                "table_name": {"type": "string", "description": "Table name, optionally with schema prefix"}
            },
            "required": ["table_name"]
        }
    },
    {
        "name": "get_context",
        "description": "CALL THIS FIRST before writing any query. Returns CSC Leasing domain knowledge: entity relationships, join paths, schema rules (IsDeleted filters, sf. prefix), equipment search strategy, financial metrics, stage/status picklists, and billing view documentation. Essential for writing correct queries.",
        "inputSchema": {
            "type": "object",
            "properties": {}
        }
    }
]

def handle_request(request):
    method = request.get("method")
    req_id = request.get("id")
    params = request.get("params", {})

    if method == "initialize":
        log("Received initialize request")
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": "csc-azure-sql", "version": "1.0.0"}
            }
        }
    elif method == "notifications/initialized":
        log("Client initialized")
        return None
    elif method == "tools/list":
        log("Listing tools")
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {"tools": TOOLS}
        }
    elif method == "tools/call":
        tool_name = params.get("name")
        args = params.get("arguments", {})
        log(f"Calling tool: {tool_name}")
        try:
            if tool_name == "query":
                result = execute_query(args["sql"], max_rows=args.get("max_rows", 5000))
            elif tool_name == "list_tables":
                result = list_tables()
            elif tool_name == "describe_table":
                result = describe_table(args["table_name"])
            elif tool_name == "get_context":
                result = get_context()
            else:
                result = {"error": f"Unknown tool: {tool_name}"}

            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "content": [{"type": "text", "text": json.dumps(result, indent=2)}]
                }
            }
        except Exception as e:
            log(f"Tool error: {e}")
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "content": [{"type": "text", "text": f"Error: {str(e)}"}],
                    "isError": True
                }
            }
    else:
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "error": {"code": -32601, "message": f"Method not found: {method}"}
        }

def main():
    log("Entering main loop, waiting for JSON-RPC messages on stdin...")

    while True:
        try:
            line = sys.stdin.readline()
            if not line:
                log("stdin closed, exiting")
                break
            line = line.strip()
            if not line:
                continue
            log(f"Received: {line[:200]}")
            request = json.loads(line)
            response = handle_request(request)
            if response is not None:
                out = json.dumps(response)
                sys.stdout.write(out + "\n")
                sys.stdout.flush()
                log(f"Sent response for method={request.get('method')}")
        except json.JSONDecodeError as e:
            log(f"JSON parse error: {e}")
            continue
        except Exception as e:
            log(f"Unexpected error: {e}")

if __name__ == "__main__":
    main()
