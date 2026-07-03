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

// GetAllTools returns all available MCP tools
func GetAllTools() []Tool {
	return []Tool{
		// a2sitemgr - Apache2 Site Manager (async)
		{
			Name:        "a2sitemgr",
			Description: "Configure Apache2 virtual hosts with domain, proxypass, or subdomain wildcard modes. Returns a jobId for async tracking.",
			InputSchema: InputSchema{
				Type: "object",
				Properties: map[string]Property{
					"fqdn": {
						Type:        "string",
						Description: "Fully-qualified domain name to manage (e.g., example.com)",
					},
					"mode": {
						Type:        "string",
						Description: "Operation mode",
						Enum:        []string{"domain", "proxypass", "swc"},
						Default:     "domain",
					},
					"registrar": {
						Type:        "string",
						Description: "Registrar credential profile for DNS/cert actions (e.g., namecheap.com)",
					},
					"port": {
						Type:        "integer",
						Description: "Backend port (required for proxypass mode)",
					},
					"secured": {
						Type:        "boolean",
						Description: "Use HTTPS for proxypass target",
						Default:     false,
					},
					"setInitDNSRecords": {
						Type:        "boolean",
						Description: "Auto-set initial DNS records (A @, A *, MX @)",
						Default:     false,
					},
					"override": {
						Type:        "boolean",
						Description: "Delete existing DNS records before setting new ones",
						Default:     false,
					},
					"verbose": {
						Type:        "boolean",
						Description: "Enable verbose output",
						Default:     true,
					},
				},
				Required: []string{"fqdn"},
			},
		},

		// fqdnmgr_check - Check domain status (sync)
		{
			Name:        "fqdnmgr_check",
			Description: "Check domain status (free/owned/taken/unavailable) via registrar API or local database.",
			InputSchema: InputSchema{
				Type: "object",
				Properties: map[string]Property{
					"fqdn": {
						Type:        "string",
						Description: "Domain name to check (e.g., example.com)",
					},
					"registrar": {
						Type:        "string",
						Description: "Registrar to query (optional, checks local DB if omitted)",
					},
					"verbose": {
						Type:        "boolean",
						Description: "Enable verbose output",
						Default:     false,
					},
				},
				Required: []string{"fqdn"},
			},
		},

		// fqdnmgr_purchase - Purchase domain (async)
		{
			Name:        "fqdnmgr_purchase",
			Description: "Purchase a domain through a registrar. Returns a jobId for async tracking.",
			InputSchema: InputSchema{
				Type: "object",
				Properties: map[string]Property{
					"fqdn": {
						Type:        "string",
						Description: "Domain name to purchase (e.g., example.com)",
					},
					"registrar": {
						Type:        "string",
						Description: "Registrar to use (e.g., namecheap.com, wedos.com)",
					},
					"verbose": {
						Type:        "boolean",
						Description: "Enable verbose output",
						Default:     true,
					},
				},
				Required: []string{"fqdn", "registrar"},
			},
		},

		// fqdnmgr_list - List domains (sync)
		{
			Name:        "fqdnmgr_list",
			Description: "List domains from local database or remote registrar API.",
			InputSchema: InputSchema{
				Type: "object",
				Properties: map[string]Property{
					"registrar": {
						Type:        "string",
						Description: "Filter by registrar (optional)",
					},
					"source": {
						Type:        "string",
						Description: "Data source",
						Enum:        []string{"local", "remote"},
						Default:     "local",
					},
					"verbose": {
						Type:        "boolean",
						Description: "Enable verbose output",
						Default:     false,
					},
				},
				Required: []string{},
			},
		},

		// fqdnmgr_setInitDNSRecords - Set initial DNS records (async)
		{
			Name:        "fqdnmgr_setInitDNSRecords",
			Description: "Set initial DNS records (A @, A *, MX @) for domains. Returns a jobId for async tracking. Use fqdnmgr_checkInitDns to poll for propagation.",
			InputSchema: InputSchema{
				Type: "object",
				Properties: map[string]Property{
					"domains": {
						Type:        "string",
						Description: "Space-separated list of domains (e.g., 'example.com example.org')",
					},
					"registrar": {
						Type:        "string",
						Description: "Registrar to use for DNS API",
					},
					"override": {
						Type:        "boolean",
						Description: "Delete existing DNS records before setting new ones",
						Default:     false,
					},
					"verbose": {
						Type:        "boolean",
						Description: "Enable verbose output (shows propagation progress)",
						Default:     true,
					},
				},
				Required: []string{"domains", "registrar"},
			},
		},

		// fqdnmgr_checkInitDns - Check DNS propagation (sync)
		{
			Name:        "fqdnmgr_checkInitDns",
			Description: "Check if initial DNS records have propagated for a domain. Returns propagation status.",
			InputSchema: InputSchema{
				Type: "object",
				Properties: map[string]Property{
					"fqdn": {
						Type:        "string",
						Description: "Domain name to check (e.g., example.com)",
					},
					"verbose": {
						Type:        "boolean",
						Description: "Enable verbose output",
						Default:     false,
					},
				},
				Required: []string{"fqdn"},
			},
		},

		// fqdncredmgr_delete - Delete credentials (sync)
		{
			Name:        "fqdncredmgr_delete",
			Description: "Delete stored credentials for a DNS provider.",
			InputSchema: InputSchema{
				Type: "object",
				Properties: map[string]Property{
					"provider": {
						Type:        "string",
						Description: "Provider name (e.g., namecheap.com, wedos.com)",
					},
					"verbose": {
						Type:        "boolean",
						Description: "Enable verbose output",
						Default:     false,
					},
				},
				Required: []string{"provider"},
			},
		},

		// fqdncredmgr_list - List credentials (sync)
		{
			Name:        "fqdncredmgr_list",
			Description: "List stored DNS provider credentials (usernames masked).",
			InputSchema: InputSchema{
				Type: "object",
				Properties: map[string]Property{
					"verbose": {
						Type:        "boolean",
						Description: "Enable verbose output",
						Default:     false,
					},
				},
				Required: []string{},
			},
		},

		// a2wcrecalc - Recalculate wildcard subdomains (sync)
		{
			Name:        "a2wcrecalc",
			Description: "Recalculate Apache wildcard subdomain configurations across all vhosts.",
			InputSchema: InputSchema{
				Type: "object",
				Properties: map[string]Property{
					"wildcardDomain": {
						Type:        "string",
						Description: "Specific wildcard domain to process (e.g., 'mail.*'). Processes all if omitted.",
					},
				},
				Required: []string{},
			},
		},

		// a2wcrecalc_dms - Recalculate for Docker-Mailserver (sync)
		{
			Name:        "a2wcrecalc_dms",
			Description: "Recalculate Apache wildcard configurations and generate SNI certificate maps for Docker-Mailserver.",
			InputSchema: InputSchema{
				Type: "object",
				Properties: map[string]Property{
					"dmsDir": {
						Type:        "string",
						Description: "Path to docker-mailserver directory",
						Default:     "/opt/compose/docker-mailserver",
					},
				},
				Required: []string{},
			},
		},

		// a2certrenew - Certificate renewal (async)
		{
			Name:        "a2certrenew",
			Description: "Check and renew SSL certificates that are expiring within 10 days. Returns a jobId for async tracking.",
			InputSchema: InputSchema{
				Type:       "object",
				Properties: map[string]Property{},
				Required:   []string{},
			},
		},

		// check_job_status - Check async job status (sync)
		{
			Name:        "check_job_status",
			Description: "Check the status of an async job. Returns current status and buffered output.",
			InputSchema: InputSchema{
				Type: "object",
				Properties: map[string]Property{
					"jobId": {
						Type:        "string",
						Description: "Job ID returned by an async tool call",
					},
				},
				Required: []string{"jobId"},
			},
		},
	}
}
