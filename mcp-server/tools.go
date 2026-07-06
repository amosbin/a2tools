package main

// Tool represents an MCP tool definition
type Tool struct {
	Name        string      `json:"name"`
	Description string      `json:"description"`
	InputSchema InputSchema `json:"inputSchema"`
}

type InputSchema struct {
	Type       string              `json:"type"`
	Properties map[string]Property `json:"properties,omitempty"`
	Required   []string            `json:"required,omitempty"`
}

type Property struct {
	Type        string   `json:"type"`
	Description string   `json:"description"`
	Enum        []string `json:"enum,omitempty"`
	Default     any      `json:"default,omitempty"`
}

// GetAllTools returns all available MCP tools.
//
// All tool descriptions and schemas mirror the current a2tools CLI surface
// (see debian/a2tools/usr/lib/a2tools/*.sh). Notable facts the schemas
// must reflect:
//   - a2sitemgr is fully flag-only (positional FQDN is rejected).
//   - fqdncredmgr remains positional for the action + provider / username
//     (the action's signature is `add|update|delete <PROVIDER> [USERNAME]`).
//   - fqdnmgr subcommands take positional arguments (e.g. `check <FQDN>`
//     `[REGISTRAR]`) EXCEPT for `setInitDNSRecords`, which is flag-only
//     (-d, -r, -o, --sync, --timeout) because the value list for -d may
//     contain spaces.
//   - There is no fqdncredmgrd daemon anymore. Credentials are read by
//     the scripts directly from /var/lib/a2tools/creds.db (see
//     lib/common.sh:creds_get). The MCP server therefore only needs the
//     `a2cmds` binary path; the README previously claimed a daemon was
//     required.
func GetAllTools() []Tool {
	return []Tool{
		// a2sitemgr - Apache2 Site Manager (async, must be run as root)
		{
			Name:        "a2sitemgr",
			Description: "Configure Apache2 virtual hosts (domain / proxypass / swc modes). Flags-only: a positional FQDN is REJECTED, use -d. Returns a jobId for async tracking. The tool must be run as root; non-root invocations exit 1. Apache modules rewrite + ssl are required; proxypass additionally needs proxy + proxy_http.",
			InputSchema: InputSchema{
				Type: "object",
				Properties: map[string]Property{
					"fqdn": {
						Type:        "string",
						Description: "Fully-qualified domain name to manage (e.g. example.com). For swc mode use the wildcard form 'subdomain.*' (e.g. mail.*).",
					},
					"mode": {
						Type:        "string",
						Description: "Operation mode. 'domain' = standard vhost (default). 'pp' or 'proxypass' = reverse-proxied subdomain (requires -p). 'swc' or 'subdomainWildCard' = one subdomain served for every base domain (no -s/-p/-r allowed).",
						Enum:        []string{"domain", "pp", "proxypass", "swc", "subdomainWildCard"},
						Default:     "domain",
					},
					"registrar": {
						Type:        "string",
						Description: "Registrar credential profile (e.g. namecheap.com) for DNS / cert actions. Must already be present in fqdncredmgr. Short names like 'namecheap' are resolved by substring match against fqdncredmgr list.",
					},
					"port": {
						Type:        "integer",
						Description: "Backend / proxy port (1-65535). Required for proxypass / pp mode; rejected for swc and domain modes.",
					},
					"secured": {
						Type:        "boolean",
						Description: "Use HTTPS for the proxypass target (sets proxy protocol to https). Only valid with proxypass / pp mode; rejected for swc.",
						Default:     false,
					},
					"setInitDNSRecords": {
						Type:        "boolean",
						Description: "Automatically set the initial DNS records (A @, A *, MX @) via fqdnmgr setInitDNSRecords before the cert request. Requires -r/--registrar. Can be combined with -o/--override and --sync.",
						Default:     false,
					},
					"override": {
						Type:        "boolean",
						Description: "Used with --setInitDNSRecords: delete all existing DNS records at the registrar before setting the initial three. Without this flag, existing records are preserved and init records are added/updated.",
						Default:     false,
					},
					"sync": {
						Type:        "boolean",
						Description: "Used with --setInitDNSRecords: wait for DNS propagation before continuing with the certificate request. The wait is bounded by the registrar's setInitDNSRecords --timeout (default 600s).",
						Default:     false,
					},
					"nonInteractive": {
						Type:        "boolean",
						Description: "Non-interactive mode (-ni): accept defaults and auto-yes to overwrite prompts instead of asking. Always set this true when invoking from MCP - there is no terminal for the script to prompt on.",
						Default:     true,
					},
					"verbose": {
						Type:        "boolean",
						Description: "Verbose (-v): extra status messages and progress to FD 3.",
						Default:     false,
					},
				},
				Required: []string{"fqdn"},
			},
		},

		// fqdnmgr_check - Check domain status (sync)
		{
			Name:        "fqdnmgr_check",
			Description: "Check a domain's status (free / owned / taken / unavailable) via registrar API or local SQLite DB. The first positional argument is the FQDN; the optional second positional is the registrar. -v can be added anywhere and is stripped before the subcommand dispatches.",
			InputSchema: InputSchema{
				Type: "object",
				Properties: map[string]Property{
					"fqdn": {
						Type:        "string",
						Description: "Domain to check (e.g. example.com). Must be a fully-qualified name; bare labels are rejected.",
					},
					"registrar": {
						Type:        "string",
						Description: "Optional registrar to query (e.g. namecheap.com). If omitted, the local domains DB is consulted (returns 'owned' if present, otherwise 'unknown').",
					},
					"verbose": {
						Type:        "boolean",
						Description: "Verbose output (-v).",
						Default:     false,
					},
				},
				Required: []string{"fqdn"},
			},
		},

		// fqdnmgr_purchase - Purchase a domain (async)
		{
			Name:        "fqdnmgr_purchase",
			Description: "Purchase a domain through a registrar. Two required POSITIONAL arguments: <FQDN> <REGISTRAR>. Long-running: returns a jobId; poll with check_job_status.",
			InputSchema: InputSchema{
				Type: "object",
				Properties: map[string]Property{
					"fqdn": {
						Type:        "string",
						Description: "Domain to purchase (e.g. example.com).",
					},
					"registrar": {
						Type:        "string",
						Description: "Registrar to use (e.g. namecheap.com, wedos.com). Must be a credentialed provider (see fqdncredmgr list).",
					},
					"verbose": {
						Type:        "boolean",
						Description: "Verbose output (-v).",
						Default:     false,
					},
				},
				Required: []string{"fqdn", "registrar"},
			},
		},

		// fqdnmgr_list - List domains (sync)
		{
			Name:        "fqdnmgr_list",
			Description: "List domains. Two optional POSITIONAL arguments: [REGISTRAR] [local|remote]. With neither, lists all local DB domains (machine-parsable). With REGISTRAR + 'local', queries the local DB for that registrar; with REGISTRAR + 'remote', queries the registrar's API.",
			InputSchema: InputSchema{
				Type: "object",
				Properties: map[string]Property{
					"registrar": {
						Type:        "string",
						Description: "Filter by registrar (e.g. namecheap.com). Omit to list domains from all registrars in the local DB.",
					},
					"source": {
						Type:        "string",
						Description: "Data source. 'local' = the SQLite DB (default). 'remote' = the registrar's API. If 'remote' is set, registrar is required.",
						Enum:        []string{"local", "remote"},
						Default:     "local",
					},
					"verbose": {
						Type:        "boolean",
						Description: "Verbose output (-v).",
						Default:     false,
					},
				},
				Required: []string{},
			},
		},

		// fqdnmgr_setInitDNSRecords - Set initial DNS records (async)
		{
			Name:        "fqdnmgr_setInitDNSRecords",
			Description: "Set the initial DNS records (A @, A *, MX @) for one or more domains. Flag-only: at least one of -d or -r is required. -d takes a space-separated list of FQDNs (quote it in the shell). If -r is given without -d, every owned domain at the registrar is processed (and with -v, an interactive picker is shown - NOT what the MCP server wants, so leave -d set). Returns a jobId; poll with check_job_status. With --sync the call BLOCKS until propagation (bounded by --timeout, default 600s).",
			InputSchema: InputSchema{
				Type: "object",
				Properties: map[string]Property{
					"domains": {
						Type:        "string",
						Description: "Space-separated list of domains to initialize (e.g. 'example.com example.org'). At least one of domains or registrar is required.",
					},
					"registrar": {
						Type:        "string",
						Description: "Registrar to use for the DNS API. Required if 'domains' is omitted (processes all owned domains); optional hint if 'domains' is set.",
					},
					"override": {
						Type:        "boolean",
						Description: "Override (-o): delete all existing DNS records before setting only the three init records. Without this, existing records are preserved and init records are added/updated.",
						Default:     false,
					},
					"sync": {
						Type:        "boolean",
						Description: "Wait for DNS propagation before returning. Bounded by 'timeout'.",
						Default:     false,
					},
					"timeout": {
						Type:        "integer",
						Description: "Max wait (seconds) for DNS propagation when --sync is set. Positive integer; default 600 (10 minutes).",
						Default:     600,
					},
					"verbose": {
						Type:        "boolean",
						Description: "Verbose output (-v).",
						Default:     false,
					},
				},
				Required: []string{},
			},
		},

		// fqdnmgr_checkInitDns - Check whether the initial DNS records have propagated (sync)
		{
			Name:        "fqdnmgr_checkInitDns",
			Description: "Check whether the initial A / A-wildcard / MX records for a domain have propagated to authoritative resolvers. Single positional argument: the FQDN. Requires WAN IP discovery (DNS / HTTPS).",
			InputSchema: InputSchema{
				Type: "object",
				Properties: map[string]Property{
					"fqdn": {
						Type:        "string",
						Description: "Domain to check (e.g. example.com).",
					},
					"verbose": {
						Type:        "boolean",
						Description: "Verbose output (-v).",
						Default:     false,
					},
				},
				Required: []string{"fqdn"},
			},
		},

		// fqdnmgr_certify - Set up DNS-01 challenge records for certbot (sync, certbot hook)
		{
			Name:        "fqdnmgr_certify",
			Description: "Set up the DNS-01 challenge records at the registrar before certbot issues a certificate. Certbot invokes this via the 'auth' hook shipped with a2tools; the MCP tool is useful for manual reruns and debugging. Single POSITIONAL argument: the REGISTRAR.",
			InputSchema: InputSchema{
				Type: "object",
				Properties: map[string]Property{
					"registrar": {
						Type:        "string",
						Description: "Registrar where the DNS-01 challenge records should be created (e.g. namecheap.com).",
					},
					"verbose": {
						Type:        "boolean",
						Description: "Verbose output (-v).",
						Default:     false,
					},
				},
				Required: []string{"registrar"},
			},
		},

		// fqdnmgr_cleanup - Remove DNS-01 challenge records (sync, certbot hook)
		{
			Name:        "fqdnmgr_cleanup",
			Description: "Remove the DNS-01 challenge records that the 'certify' step created. Certbot invokes this via the 'cleanup' hook; the MCP tool is useful for manual reruns and debugging. Single POSITIONAL argument: the REGISTRAR.",
			InputSchema: InputSchema{
				Type: "object",
				Properties: map[string]Property{
					"registrar": {
						Type:        "string",
						Description: "Registrar whose challenge records should be removed (e.g. namecheap.com).",
					},
					"verbose": {
						Type:        "boolean",
						Description: "Verbose output (-v).",
						Default:     false,
					},
				},
				Required: []string{"registrar"},
			},
		},

		// fqdncredmgr_delete - Delete stored credentials (sync)
		{
			Name:        "fqdncredmgr_delete",
			Description: "Delete stored credentials for a DNS provider from /var/lib/a2tools/creds.db. Single POSITIONAL argument: the PROVIDER (e.g. namecheap.com).",
			InputSchema: InputSchema{
				Type: "object",
				Properties: map[string]Property{
					"provider": {
						Type:        "string",
						Description: "Provider name (e.g. namecheap.com, wedos.com). Must be a registered provider plugin (see /usr/lib/a2tools/providers/*.provider).",
					},
					"verbose": {
						Type:        "boolean",
						Description: "Verbose output (-v).",
						Default:     false,
					},
				},
				Required: []string{"provider"},
			},
		},

		// fqdncredmgr_list - List stored credentials (sync)
		{
			Name:        "fqdncredmgr_list",
			Description: "List stored DNS provider credentials. Usernames are MASKED on output (e.g. 'a***e@n**cheap.com') so they are safe to surface to the LLM. No arguments required.",
			InputSchema: InputSchema{
				Type: "object",
				Properties: map[string]Property{
					"verbose": {
						Type:        "boolean",
						Description: "Verbose output (-v).",
						Default:     false,
					},
				},
				Required: []string{},
			},
		},

		// a2wcrecalc - Recalculate Apache wildcard subdomain configs (sync)
		{
			Name:        "a2wcrecalc",
			Description: "Recalculate Apache wildcard subdomain configurations. No flags - one optional POSITIONAL argument: a wildcard FQDN like 'mail.*'. Without an argument, every wildcard found in /etc/apache2/sites-available is recalculated against every base domain. Must be run as root.",
			InputSchema: InputSchema{
				Type: "object",
				Properties: map[string]Property{
					"wildcardDomain": {
						Type:        "string",
						Description: "Specific wildcard to process (e.g. 'mail.*'). Omit to recalculate all wildcards.",
					},
				},
				Required: []string{},
			},
		},

		// a2wcrecalc_dms - Recalculate wildcards AND write DMS SNI / Dovecot maps (sync)
		{
			Name:        "a2wcrecalc_dms",
			Description: "Recalculate Apache wildcard configs AND regenerate the Docker-Mailserver SNI files (sni_cert_map and 99-sni.conf) so the mail server can present per-domain certs over a single mail.* vhost. One optional POSITIONAL argument: the DMS directory (default /opt/compose/docker-mailserver). Must be run as root.",
			InputSchema: InputSchema{
				Type: "object",
				Properties: map[string]Property{
					"dmsDir": {
						Type:        "string",
						Description: "Path to the docker-mailserver directory containing docker-data/dms/config/. Defaults to /opt/compose/docker-mailserver.",
						Default:     "/opt/compose/docker-mailserver",
					},
				},
				Required: []string{},
			},
		},

		// a2certrenew - Pass-through to `certbot renew` (async, but typically fast)
		{
			Name:        "a2certrenew",
			Description: "Force a certbot renew pass and tee the output to /var/log/a2tools/a2certrenew.log. Any arguments are forwarded to `certbot renew` (e.g. --force-renewal, --cert-name example.com, --dry-run). Routine renewals happen on certbot's own systemd timer - this tool is for manual/forced runs. Must be run as root with certbot installed. Returns a jobId.",
			InputSchema: InputSchema{
				Type: "object",
				Properties: map[string]Property{
					"certbotArgs": {
						Type:        "array",
						Description: "Optional extra arguments forwarded verbatim to `certbot renew` (e.g. ['--force-renewal', '--cert-name', 'example.com']).",
					},
				},
				Required: []string{},
			},
		},

		// check_job_status - Poll an async job (sync)
		{
			Name:        "check_job_status",
			Description: "Check the status of an async job. Returns the current status (running / completed / failed), the buffered last-50 lines of stdout, and the captured stderr. Jobs are garbage-collected 10 minutes after completion.",
			InputSchema: InputSchema{
				Type: "object",
				Properties: map[string]Property{
					"jobId": {
						Type:        "string",
						Description: "Job ID returned by an async tool call (a2sitemgr, fqdnmgr_purchase, fqdnmgr_setInitDNSRecords, a2certrenew).",
					},
				},
				Required: []string{"jobId"},
			},
		},
	}
}
