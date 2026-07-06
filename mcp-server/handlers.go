package main

import (
	"bytes"
	"fmt"
	"os/exec"
	"strings"
)

// ExecuteTool dispatches tool calls to the appropriate handler.
//
// Command shape (mirrors the on-disk scripts in
// debian/a2tools/usr/lib/a2tools/*.sh):
//
//	a2sitemgr      : flag-only. -d is mandatory. -m default 'domain'.
//	a2certrenew    : no flags of its own; all args forward to certbot.
//	a2wcrecalc     : one optional POSITIONAL arg (wildcard FQDN).
//	a2wcrecalc-dms : one optional POSITIONAL arg (DMS directory).
//	fqdncredmgr    : positional: ACTION <PROVIDER> [USERNAME].
//	fqdnmgr <sub>: POSITIONAL args for check/purchase/list/checkInitDns
//	               /certify/cleanup. FLAG-only for setInitDNSRecords.
//
// All scripts strip -v (and a2sitemgr also strips -ni) before dispatching,
// so the order of -v relative to subcommand / flags does not matter.
func ExecuteTool(name string, args map[string]any) ToolCallResult {
	switch name {
	case "a2sitemgr":
		return handleA2SiteMgr(args)
	case "fqdnmgr_check":
		return handleFQDNMgrCheck(args)
	case "fqdnmgr_purchase":
		return handleFQDNMgrPurchase(args)
	case "fqdnmgr_list":
		return handleFQDNMgrList(args)
	case "fqdnmgr_setInitDNSRecords":
		return handleFQDNMgrSetInitDNS(args)
	case "fqdnmgr_checkInitDns":
		return handleFQDNMgrCheckInitDns(args)
	case "fqdnmgr_certify":
		return handleFQDNMgrCertify(args)
	case "fqdnmgr_cleanup":
		return handleFQDNMgrCleanup(args)
	case "fqdncredmgr_delete":
		return handleFQDNCredMgrDelete(args)
	case "fqdncredmgr_list":
		return handleFQDNCredMgrList(args)
	case "a2wcrecalc":
		return handleA2WCRecalc(args)
	case "a2wcrecalc_dms":
		return handleA2WCRecalcDMS(args)
	case "a2certrenew":
		return handleA2CertRenew(args)
	case "check_job_status":
		return handleCheckJobStatus(args)
	default:
		return errorResult(fmt.Sprintf("Unknown tool: %s", name))
	}
}

// ----------------- argument helpers -----------------

func getString(args map[string]any, key string, defaultVal string) string {
	if v, ok := args[key]; ok {
		if s, ok := v.(string); ok {
			return s
		}
	}
	return defaultVal
}

func getBool(args map[string]any, key string, defaultVal bool) bool {
	if v, ok := args[key]; ok {
		if b, ok := v.(bool); ok {
			return b
		}
	}
	return defaultVal
}

func getInt(args map[string]any, key string, defaultVal int) int {
	if v, ok := args[key]; ok {
		switch n := v.(type) {
		case float64:
			return int(n)
		case int:
			return n
		}
	}
	return defaultVal
}

// getStringList returns a []string for arrays of strings. Other element
// types are coerced via fmt.Sprint (numbers, bools). nil if the property
// is missing or not an array.
func getStringList(args map[string]any, key string) []string {
	v, ok := args[key]
	if !ok || v == nil {
		return nil
	}
	arr, ok := v.([]any)
	if !ok {
		return nil
	}
	out := make([]string, 0, len(arr))
	for _, e := range arr {
		switch t := e.(type) {
		case string:
			out = append(out, t)
		default:
			out = append(out, fmt.Sprint(t))
		}
	}
	return out
}

// ----------------- result helpers -----------------

func errorResult(msg string) ToolCallResult {
	return ToolCallResult{
		Content: []ContentBlock{{Type: "text", Text: msg}},
		IsError: true,
	}
}

func textResult(msg string) ToolCallResult {
	return ToolCallResult{
		Content: []ContentBlock{{Type: "text", Text: msg}},
		IsError: false,
	}
}

func jobStartedResult(jobID string, checkInterval string) ToolCallResult {
	msg := fmt.Sprintf("Job started with ID: %s\n\nUse check_job_status with this jobId to monitor progress. Check again in %s.", jobID, checkInterval)
	return textResult(msg)
}

// runSync executes a command synchronously and returns stdout/stderr.
func runSync(name string, args ...string) (stdout string, stderr string, exitCode int, err error) {
	cmd := exec.Command(name, args...)
	var stdoutBuf, stderrBuf bytes.Buffer
	cmd.Stdout = &stdoutBuf
	cmd.Stderr = &stderrBuf

	err = cmd.Run()
	exitCode = 0
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			exitCode = exitErr.ExitCode()
		}
	}

	return stdoutBuf.String(), stderrBuf.String(), exitCode, nil
}

// ==================== ASYNC HANDLERS ====================

// handleA2SiteMgr - Configure Apache2 virtual hosts (async, root required).
//
// a2sitemgr is now flag-only. The positional FQDN form (e.g.
// `a2sitemgr example.com -m domain`) is REJECTED by the script's parser;
// we must pass -d. -m default is 'domain' but we always pass it
// explicitly so the intent is auditable in the spawned argv. -ni is
// also always passed because there is no TTY to prompt on from a
// non-interactive MCP server. -v is opt-in (default false here; the
// tool description tells the LLM to use verbose only when debugging).
func handleA2SiteMgr(args map[string]any) ToolCallResult {
	fqdn := getString(args, "fqdn", "")
	if fqdn == "" {
		return errorResult("fqdn is required")
	}

	mode := getString(args, "mode", "domain")
	// Canonicalize the long-form aliases the script accepts, but the
	// script also normalizes them. Pass through unchanged so the LLM
	// sees the same form it sent.

	cmdArgs := []string{"-d", fqdn, "-m", mode}

	if registrar := getString(args, "registrar", ""); registrar != "" {
		cmdArgs = append(cmdArgs, "-r", registrar)
	}

	if port := getInt(args, "port", 0); port > 0 {
		cmdArgs = append(cmdArgs, "-p", fmt.Sprintf("%d", port))
	}

	if getBool(args, "secured", false) {
		cmdArgs = append(cmdArgs, "-s")
	}

	if getBool(args, "setInitDNSRecords", false) {
		cmdArgs = append(cmdArgs, "--setInitDNSRecords")
	}

	if getBool(args, "override", false) {
		cmdArgs = append(cmdArgs, "-o")
	}

	if getBool(args, "sync", false) {
		cmdArgs = append(cmdArgs, "--sync")
	}

	// Default nonInteractive=true: the script will fail with rc 1 on
	// any prompt and there is no TTY to answer on. Tools can override
	// to false for debugging, but it will not work in practice.
	if getBool(args, "nonInteractive", true) {
		cmdArgs = append(cmdArgs, "-ni")
	}

	if getBool(args, "verbose", false) {
		cmdArgs = append(cmdArgs, "-v")
	}

	jobID, err := jobMgr.StartJob("a2sitemgr", cmdArgs...)
	if err != nil {
		return errorResult(fmt.Sprintf("Failed to start job: %v", err))
	}

	// a2sitemgr can do real work (certbot + apache reload) for several
	// minutes when --setInitDNSRecords --sync is set. The certbot
	// portion alone can take 1-2 minutes per domain. Suggest a long
	// poll interval accordingly.
	return jobStartedResult(jobID, "30-60 seconds (longer if --setInitDNSRecords --sync was used)")
}

// handleFQDNMgrPurchase - Purchase a domain (async, positional).
func handleFQDNMgrPurchase(args map[string]any) ToolCallResult {
	fqdn := getString(args, "fqdn", "")
	registrar := getString(args, "registrar", "")

	if fqdn == "" || registrar == "" {
		return errorResult("fqdn and registrar are required")
	}

	cmdArgs := []string{"purchase", fqdn, registrar}

	if getBool(args, "verbose", false) {
		cmdArgs = append(cmdArgs, "-v")
	}

	jobID, err := jobMgr.StartJob("fqdnmgr", cmdArgs...)
	if err != nil {
		return errorResult(fmt.Sprintf("Failed to start job: %v", err))
	}

	return jobStartedResult(jobID, "30 seconds")
}

// handleFQDNMgrSetInitDNS - Set initial DNS records (async, flag-only).
//
// The fqdnmgr main dispatcher strips -v before calling setInitDNSRecords,
// so we can add -v at the end and it still works. -ni is NOT a recognized
// flag inside setInitDNSRecords (it is a top-level switch that the
// dispatcher has already removed), so we deliberately don't pass it.
func handleFQDNMgrSetInitDNS(args map[string]any) ToolCallResult {
	domains := getString(args, "domains", "")
	registrar := getString(args, "registrar", "")

	if domains == "" && registrar == "" {
		return errorResult("at least one of 'domains' or 'registrar' is required")
	}

	cmdArgs := []string{"setInitDNSRecords"}

	if domains != "" {
		// The script splits this string on whitespace. Quote it on the
		// way through; we are NOT going through a shell so no escaping
		// is required - the entire string is one argv element.
		cmdArgs = append(cmdArgs, "-d", domains)
	}

	if registrar != "" {
		cmdArgs = append(cmdArgs, "-r", registrar)
	}

	if getBool(args, "override", false) {
		cmdArgs = append(cmdArgs, "-o")
	}

	if getBool(args, "sync", false) {
		cmdArgs = append(cmdArgs, "--sync")
	}

	if timeout := getInt(args, "timeout", 0); timeout > 0 {
		cmdArgs = append(cmdArgs, "--timeout", fmt.Sprintf("%d", timeout))
	}

	if getBool(args, "verbose", false) {
		cmdArgs = append(cmdArgs, "-v")
	}

	jobID, err := jobMgr.StartJob("fqdnmgr", cmdArgs...)
	if err != nil {
		return errorResult(fmt.Sprintf("Failed to start job: %v", err))
	}

	checkIn := "30-60 seconds (5-10 minutes if --sync is set; max --timeout seconds)"
	return jobStartedResult(jobID, checkIn)
}

// handleA2CertRenew - Pass-through to `certbot renew` (async).
//
// a2certrenew is just `certbot renew "$@"`; it doesn't take its own
// flags. Any certbot-style arguments are forwarded. The tool is async
// because certbot can take a while (network calls, apache reload),
// and we want the LLM to be able to poll.
func handleA2CertRenew(args map[string]any) ToolCallResult {
	var cmdArgs []string

	for _, a := range getStringList(args, "certbotArgs") {
		cmdArgs = append(cmdArgs, a)
	}

	jobID, err := jobMgr.StartJob("a2certrenew", cmdArgs...)
	if err != nil {
		return errorResult(fmt.Sprintf("Failed to start job: %v", err))
	}

	return jobStartedResult(jobID, "30-60 seconds")
}

// ==================== SYNC HANDLERS ====================

// handleFQDNMgrCheck - Check domain status (sync, positional).
func handleFQDNMgrCheck(args map[string]any) ToolCallResult {
	fqdn := getString(args, "fqdn", "")
	if fqdn == "" {
		return errorResult("fqdn is required")
	}

	cmdArgs := []string{"check", fqdn}

	if registrar := getString(args, "registrar", ""); registrar != "" {
		cmdArgs = append(cmdArgs, registrar)
	}

	if getBool(args, "verbose", false) {
		cmdArgs = append(cmdArgs, "-v")
	}

	stdout, stderr, exitCode, _ := runSync("fqdnmgr", cmdArgs...)

	output := formatOutput(stdout, stderr, exitCode)
	return textResult(output)
}

// handleFQDNMgrList - List domains (sync, positional).
//
// `fqdnmgr list` accepts zero, one, or two positional arguments:
//   - 0 args        : all domains in the local DB
//   - 1 arg (REG)   : error (mode local|remote is required when REG is set)
//   - 2 args (REG, mode): local|remote filter
//
// We reconstruct the exact argv the script expects.
func handleFQDNMgrList(args map[string]any) ToolCallResult {
	cmdArgs := []string{"list"}

	registrar := getString(args, "registrar", "")
	source := getString(args, "source", "")

	if registrar != "" {
		cmdArgs = append(cmdArgs, registrar)
		// source is required when registrar is set
		if source == "" {
			source = "local"
		}
		cmdArgs = append(cmdArgs, source)
	}
	// If only source is set, that's an error in the script - but the
	// MCP schema documents that source=remote requires registrar, so
	// the LLM shouldn't set them separately. Pass them through anyway
	// and let the script produce its helpful "Usage: $0 list ..." error.

	if getBool(args, "verbose", false) {
		cmdArgs = append(cmdArgs, "-v")
	}

	stdout, stderr, exitCode, _ := runSync("fqdnmgr", cmdArgs...)

	output := formatOutput(stdout, stderr, exitCode)
	return textResult(output)
}

// handleFQDNMgrCheckInitDns - Check DNS propagation (sync, positional).
func handleFQDNMgrCheckInitDns(args map[string]any) ToolCallResult {
	fqdn := getString(args, "fqdn", "")
	if fqdn == "" {
		return errorResult("fqdn is required")
	}

	cmdArgs := []string{"checkInitDns", fqdn}

	if getBool(args, "verbose", false) {
		cmdArgs = append(cmdArgs, "-v")
	}

	stdout, stderr, exitCode, _ := runSync("fqdnmgr", cmdArgs...)

	output := formatOutput(stdout, stderr, exitCode)

	if exitCode != 0 {
		output += "\n\nDNS not fully propagated. Check again in 60 seconds."
	} else {
		output += "\n\nDNS propagation complete."
	}

	return textResult(output)
}

// handleFQDNMgrCertify - Set up DNS-01 challenge (sync, positional).
//
// This is normally called by certbot's auth hook; the MCP tool exists
// for manual runs and debugging.
func handleFQDNMgrCertify(args map[string]any) ToolCallResult {
	registrar := getString(args, "registrar", "")
	if registrar == "" {
		return errorResult("registrar is required")
	}

	cmdArgs := []string{"certify", registrar}

	if getBool(args, "verbose", false) {
		cmdArgs = append(cmdArgs, "-v")
	}

	stdout, stderr, exitCode, _ := runSync("fqdnmgr", cmdArgs...)

	output := formatOutput(stdout, stderr, exitCode)
	return textResult(output)
}

// handleFQDNMgrCleanup - Remove DNS-01 challenge (sync, positional).
func handleFQDNMgrCleanup(args map[string]any) ToolCallResult {
	registrar := getString(args, "registrar", "")
	if registrar == "" {
		return errorResult("registrar is required")
	}

	cmdArgs := []string{"cleanup", registrar}

	if getBool(args, "verbose", false) {
		cmdArgs = append(cmdArgs, "-v")
	}

	stdout, stderr, exitCode, _ := runSync("fqdnmgr", cmdArgs...)

	output := formatOutput(stdout, stderr, exitCode)
	return textResult(output)
}

// handleFQDNCredMgrDelete - Delete credentials (sync, positional).
//
// fqdncredmgr keeps its positional shape: `delete <PROVIDER>`. There is
// no --provider flag on this action in the current script.
func handleFQDNCredMgrDelete(args map[string]any) ToolCallResult {
	provider := getString(args, "provider", "")
	if provider == "" {
		return errorResult("provider is required")
	}

	cmdArgs := []string{"delete", provider}

	if getBool(args, "verbose", false) {
		cmdArgs = append(cmdArgs, "-v")
	}

	stdout, stderr, exitCode, _ := runSync("fqdncredmgr", cmdArgs...)

	output := formatOutput(stdout, stderr, exitCode)
	return textResult(output)
}

// handleFQDNCredMgrList - List credentials (sync, no args).
func handleFQDNCredMgrList(args map[string]any) ToolCallResult {
	cmdArgs := []string{"list"}

	if getBool(args, "verbose", false) {
		cmdArgs = append(cmdArgs, "-v")
	}

	stdout, stderr, exitCode, _ := runSync("fqdncredmgr", cmdArgs...)

	output := formatOutput(stdout, stderr, exitCode)
	return textResult(output)
}

// handleA2WCRecalc - Recalculate wildcard subdomains (sync, one optional positional).
func handleA2WCRecalc(args map[string]any) ToolCallResult {
	var cmdArgs []string

	if wildcardDomain := getString(args, "wildcardDomain", ""); wildcardDomain != "" {
		cmdArgs = append(cmdArgs, wildcardDomain)
	}

	stdout, stderr, exitCode, _ := runSync("a2wcrecalc", cmdArgs...)

	output := formatOutput(stdout, stderr, exitCode)
	return textResult(output)
}

// handleA2WCRecalcDMS - Recalculate for Docker-Mailserver (sync, one optional positional).
func handleA2WCRecalcDMS(args map[string]any) ToolCallResult {
	var cmdArgs []string

	if dmsDir := getString(args, "dmsDir", ""); dmsDir != "" {
		cmdArgs = append(cmdArgs, dmsDir)
	}

	stdout, stderr, exitCode, _ := runSync("a2wcrecalc-dms", cmdArgs...)

	output := formatOutput(stdout, stderr, exitCode)
	return textResult(output)
}

// handleCheckJobStatus - Check async job status.
func handleCheckJobStatus(args map[string]any) ToolCallResult {
	jobID := getString(args, "jobId", "")
	if jobID == "" {
		return errorResult("jobId is required")
	}

	status, exitCode, output, stderr, found := jobMgr.GetJobStatus(jobID)
	if !found {
		return errorResult(fmt.Sprintf("Job not found: %s (may have expired after 10 minutes)", jobID))
	}

	var result strings.Builder
	result.WriteString(fmt.Sprintf("Status: %s\n", status))

	if status != JobStatusRunning {
		result.WriteString(fmt.Sprintf("Exit Code: %d\n", exitCode))
	}

	if output != "" {
		result.WriteString(fmt.Sprintf("\n--- Output (last %d lines) ---\n%s", MaxOutputLines, output))
	}

	if stderr != "" {
		result.WriteString(fmt.Sprintf("\n--- Stderr ---\n%s", stderr))
	}

	if status == JobStatusRunning {
		result.WriteString("\n\nJob still running. Check again in 30-60 seconds.")
	} else if status == JobStatusCompleted {
		result.WriteString("\n\nJob completed successfully.")
	} else {
		result.WriteString("\n\nJob failed. Review stderr for details.")
	}

	return textResult(result.String())
}

// formatOutput formats command output for display.
func formatOutput(stdout, stderr string, exitCode int) string {
	var result strings.Builder

	if stdout != "" {
		result.WriteString(strings.TrimSpace(stdout))
	}

	if stderr != "" {
		if result.Len() > 0 {
			result.WriteString("\n\n--- Stderr ---\n")
		}
		result.WriteString(strings.TrimSpace(stderr))
	}

	if exitCode != 0 {
		result.WriteString(fmt.Sprintf("\n\nExit code: %d", exitCode))
	}

	return result.String()
}
