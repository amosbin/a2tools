# a2cmds MCP Server

Model Context Protocol (MCP) server for a2cmds tools. Exposes Apache2 virtual host management, DNS, and certificate tools to AI assistants via stdio transport.

## Build & Install

```bash
cd mcp-server
make build      # Build binary
make install    # Install to /usr/local/bin
make uninstall  # Remove from /usr/local/bin
```

## Usage

### Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS) or `%APPDATA%\Claude\claude_desktop_config.json` (Windows):

```json
{
  "mcpServers": {
    "a2cmds": {
      "command": "/usr/local/bin/a2cmds-mcp"
    }
  }
}
```

### VS Code with Copilot

Add to your VS Code settings or workspace `.vscode/mcp.json`:

```json
{
  "servers": {
    "a2cmds": {
      "command": "/usr/local/bin/a2cmds-mcp"
    }
  }
}
```

## Available Tools

| Tool | Type | Description |
|------|------|-------------|
| `a2sitemgr` | async | Configure Apache2 virtual hosts (domain/proxypass/swc modes) |
| `fqdnmgr_check` | sync | Check domain status (free/owned/taken/unavailable) |
| `fqdnmgr_purchase` | async | Purchase a domain through registrar |
| `fqdnmgr_list` | sync | List domains from local DB or registrar API |
| `fqdnmgr_setInitDNSRecords` | async | Set initial DNS records (A @, A *, MX @) |
| `fqdnmgr_checkInitDns` | sync | Check if DNS records have propagated |
| `fqdncredmgr_delete` | sync | Delete stored registrar credentials |
| `fqdncredmgr_list` | sync | List stored registrar credentials |
| `a2wcrecalc` | sync | Recalculate Apache wildcard subdomain configs |
| `a2wcrecalc_dms` | sync | Recalculate wildcards + Docker-Mailserver SNI maps |
| `a2certrenew` | async | Check and renew expiring SSL certificates |
| `check_job_status` | sync | Check status of async jobs |

## Async Job Pattern

Long-running operations return a `jobId` immediately. Use `check_job_status` to poll:

```
1. Call fqdnmgr_setInitDNSRecords
   → Returns: {"jobId": "abc-123", "message": "Check status in 60 seconds..."}

2. Wait 60 seconds

3. Call check_job_status with jobId: "abc-123"
   → Returns: {"status": "running", "output": "Checking A record..."}

4. Repeat until status is "completed" or "failed"
```

Jobs are automatically cleaned up 10 minutes after completion.

## Testing

```bash
# Test initialization
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' | ./a2cmds-mcp

# List tools
echo '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | ./a2cmds-mcp

# Call a tool
echo '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"fqdncredmgr_list","arguments":{}}}' | ./a2cmds-mcp
```

## Requirements

- Go 1.21+
- a2cmds tools installed (`a2sitemgr`, `fqdnmgr`, `fqdncredmgr`, etc.)
- `fqdncredmgrd` service running (for credential-based operations)
