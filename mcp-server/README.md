# a2cmds MCP Server

Model Context Protocol (MCP) server for [a2cmds](../README.md) — the
Apache2 virtual-host / DNS / certificate management toolchain. Exposes
the a2cmds CLI to AI assistants over stdio JSON-RPC 2.0 transport.

## Build & Install

```bash
cd mcp-server
make build      # Build binary (./a2cmds-mcp)
make install    # Install to /usr/local/bin/a2cmds-mcp
make uninstall  # Remove from /usr/local/bin
```

## Usage

### Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS)
or `%APPDATA%\Claude\claude_desktop_config.json` (Windows):

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
| `a2sitemgr` | async | Configure Apache2 virtual hosts (domain / proxypass / swc modes). Flag-only: must use `-d`, no positional FQDN. |
| `fqdnmgr_check` | sync | Check domain status (free / owned / taken / unavailable). |
| `fqdnmgr_purchase` | async | Purchase a domain through a registrar. |
| `fqdnmgr_list` | sync | List domains from the local SQLite DB or a registrar's API. |
| `fqdnmgr_setInitDNSRecords` | async | Set initial DNS records (A @, A *, MX @). Flag-only. Supports `--sync` + `--timeout`. |
| `fqdnmgr_checkInitDns` | sync | Check whether the initial DNS records have propagated. |
| `fqdnmgr_certify` | sync | Set up DNS-01 challenge records at a registrar (certbot auth hook). |
| `fqdnmgr_cleanup` | sync | Remove DNS-01 challenge records (certbot cleanup hook). |
| `fqdncredmgr_delete` | sync | Delete stored registrar credentials from `/var/lib/a2tools/creds.db`. |
| `fqdncredmgr_list` | sync | List stored registrar credentials (usernames are masked). |
| `a2wcrecalc` | sync | Recalculate Apache wildcard subdomain configs. |
| `a2wcrecalc_dms` | sync | Recalculate wildcards AND regenerate Docker-Mailserver SNI maps. |
| `a2certrenew` | async | Force a `certbot renew` pass and tee to log. |
| `check_job_status` | sync | Poll an async job (status, last 50 lines of output, stderr). |

## Argument Style Cheat-Sheet

The MCP schemas match the underlying CLI exactly. The big rule is:

- `a2sitemgr` is **flag-only** — the script REJECTS a positional FQDN. Always pass `-d <FQDN>`. `-ni` is required in non-interactive contexts because the script has no TTY to prompt on.
- `fqdncredmgr` keeps **positional** arguments: `add|update|delete <PROVIDER> [USERNAME]`. The MCP exposes `delete` and `list`; `add`/`update` would need the key on stdin (`-p -`).
- `fqdnmgr` subcommands are **mostly positional**: `check <FQDN> [REGISTRAR]`, `purchase <FQDN> <REGISTRAR>`, `list [REGISTRAR] [local|remote]`, `checkInitDns <FQDN>`, `certify <REGISTRAR>`, `cleanup <REGISTRAR>`.
- `fqdnmgr setInitDNSRecords` is the **only flag-only** fqdnmgr subcommand: `-d "FQDN(S)"` (space-separated), `-r REGISTRAR`, `-o`, `--sync`, `--timeout SECONDS`.
- `a2wcrecalc` and `a2wcrecalc-dms` take one optional **positional** arg.
- `a2certrenew` takes zero or more forwarded `certbot` args.

`-v` is always optional and can be passed anywhere (each script strips it
before dispatching).

## Async Job Pattern

Long-running operations return a `jobId` immediately. Use `check_job_status`
to poll:

```
1. Call fqdnmgr_setInitDNSRecords
   → Returns: {"jobId": "abc-123", "message": "Check status in 30-60 seconds..."}

2. Wait 30-60 seconds (longer if --sync / --timeout is set)

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

# Call a tool (sync, no args required)
echo '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"fqdncredmgr_list","arguments":{}}}' | ./a2cmds-mcp
```

`make test` runs the initialize + tools/list smoke checks above.

## Requirements

- Go 1.21+
- The a2cmds CLI tools installed (`a2sitemgr`, `fqdnmgr`, `fqdncredmgr`,
  `a2wcrecalc`, `a2wcrecalc-dms`, `a2certrenew`) and on `$PATH` for the
  user running the MCP server. Install via the a2tools apt package.
- The a2tools scripts read registrar credentials **directly** from
  `/var/lib/a2tools/creds.db` (a root-only SQLite file managed by
  `fqdncredmgr`). There is no `fqdncredmgrd` daemon — that was
  superseded when the shared lib gained `creds_get()`. The MCP server
  does not need any extra service to be running.
- For mutating tools (`a2sitemgr`, `fqdncredmgr add|update|delete`,
  `a2wcrecalc`, `a2wcrecalc-dms`, `a2certrenew`, `fqdnmgr purchase`,
  `fqdnmgr setInitDNSRecords`, `fqdnmgr certify|cleanup`), the
  a2cmds commands must be runnable as root (sudo, rootless podman, or
  similar — out of scope for this server). The MCP server does not
  escalate privileges itself.
