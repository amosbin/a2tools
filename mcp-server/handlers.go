package main

import (
	"bytes"
	"fmt"
	"os/exec"
	"strings"
)

// ExecuteTool dispatches tool calls to the appropriate handler
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

// Helper functions
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

// runSync executes a command synchronously and returns stdout/stderr
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

// handleA2SiteMgr - Configure Apache2 virtual hosts (async)
func handleA2SiteMgr(args map[string]any) ToolCallResult {
	fqdn := getString(args, "fqdn", "")
	if fqdn == "" {
		return errorResult("fqdn is required")
	}

	cmdArgs := []string{"-d", fqdn, "-ni"}

	mode := getString(args, "mode", "domain")
	if mode != "" && mode != "domain" {
		cmdArgs = append(cmdArgs, "-m", mode)
	}

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

	if getBool(args, "verbose", true) {
		cmdArgs = append(cmdArgs, "-v")
	}

	jobID, err := jobMgr.StartJob("a2sitemgr", cmdArgs...)
	if err != nil {
		return errorResult(fmt.Sprintf("Failed to start job: %v", err))
	}

	return jobStartedResult(jobID, "30 seconds")
}

// handleFQDNMgrPurchase - Purchase domain (async)
func handleFQDNMgrPurchase(args map[string]any) ToolCallResult {
	fqdn := getString(args, "fqdn", "")
	registrar := getString(args, "registrar", "")

	if fqdn == "" || registrar == "" {
		return errorResult("fqdn and registrar are required")
	}

	cmdArgs := []string{"purchase", fqdn, registrar, "-ni"}

	if getBool(args, "verbose", true) {
		cmdArgs = append(cmdArgs, "-v")
	}

	jobID, err := jobMgr.StartJob("fqdnmgr", cmdArgs...)
	if err != nil {
		return errorResult(fmt.Sprintf("Failed to start job: %v", err))
	}

	return jobStartedResult(jobID, "30 seconds")
}

// handleFQDNMgrSetInitDNS - Set initial DNS records (async)
func handleFQDNMgrSetInitDNS(args map[string]any) ToolCallResult {
	domains := getString(args, "domains", "")
	registrar := getString(args, "registrar", "")

	if domains == "" || registrar == "" {
		return errorResult("domains and registrar are required")
	}

	cmdArgs := []string{"setInitDNSRecords", "-d", domains, "-r", registrar, "-ni"}

	if getBool(args, "override", false) {
		cmdArgs = append(cmdArgs, "-o")
	}

	if getBool(args, "verbose", true) {
		cmdArgs = append(cmdArgs, "-v")
	}

	jobID, err := jobMgr.StartJob("fqdnmgr", cmdArgs...)
	if err != nil {
		return errorResult(fmt.Sprintf("Failed to start job: %v", err))
	}

	return jobStartedResult(jobID, "60 seconds. DNS propagation typically takes 5-10 minutes")
}

// handleA2CertRenew - Certificate renewal (async)
func handleA2CertRenew(args map[string]any) ToolCallResult {
	jobID, err := jobMgr.StartJob("a2certrenew")
	if err != nil {
		return errorResult(fmt.Sprintf("Failed to start job: %v", err))
	}

	return jobStartedResult(jobID, "60 seconds")
}

// ==================== SYNC HANDLERS ====================

// handleFQDNMgrCheck - Check domain status (sync)
func handleFQDNMgrCheck(args map[string]any) ToolCallResult {
	fqdn := getString(args, "fqdn", "")
	if fqdn == "" {
		return errorResult("fqdn is required")
	}

	cmdArgs := []string{"check", fqdn, "-ni"}

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

// handleFQDNMgrList - List domains (sync)
func handleFQDNMgrList(args map[string]any) ToolCallResult {
	cmdArgs := []string{"list", "-ni"}

	if registrar := getString(args, "registrar", ""); registrar != "" {
		cmdArgs = append(cmdArgs, registrar)
	}

	source := getString(args, "source", "local")
	if source != "" {
		cmdArgs = append(cmdArgs, source)
	}

	if getBool(args, "verbose", false) {
		cmdArgs = append(cmdArgs, "-v")
	}

	stdout, stderr, exitCode, _ := runSync("fqdnmgr", cmdArgs...)

	output := formatOutput(stdout, stderr, exitCode)
	return textResult(output)
}

// handleFQDNMgrCheckInitDns - Check DNS propagation (sync)
func handleFQDNMgrCheckInitDns(args map[string]any) ToolCallResult {
	fqdn := getString(args, "fqdn", "")
	if fqdn == "" {
		return errorResult("fqdn is required")
	}

	cmdArgs := []string{"checkInitDns", fqdn, "-ni"}

	if getBool(args, "verbose", false) {
		cmdArgs = append(cmdArgs, "-v")
	}

	stdout, stderr, exitCode, _ := runSync("fqdnmgr", cmdArgs...)

	output := formatOutput(stdout, stderr, exitCode)

	// Add guidance based on result
	if exitCode != 0 {
		output += "\n\n⏳ DNS not fully propagated. Check again in 60 seconds."
	} else {
		output += "\n\n✅ DNS propagation complete."
	}

	return textResult(output)
}

// handleFQDNCredMgrDelete - Delete credentials (sync)
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

// handleFQDNCredMgrList - List credentials (sync)
func handleFQDNCredMgrList(args map[string]any) ToolCallResult {
	cmdArgs := []string{"list"}

	if getBool(args, "verbose", false) {
		cmdArgs = append(cmdArgs, "-v")
	}

	stdout, stderr, exitCode, _ := runSync("fqdncredmgr", cmdArgs...)

	output := formatOutput(stdout, stderr, exitCode)
	return textResult(output)
}

// handleA2WCRecalc - Recalculate wildcard subdomains (sync)
func handleA2WCRecalc(args map[string]any) ToolCallResult {
	var cmdArgs []string

	if wildcardDomain := getString(args, "wildcardDomain", ""); wildcardDomain != "" {
		cmdArgs = append(cmdArgs, wildcardDomain)
	}

	stdout, stderr, exitCode, _ := runSync("a2wcrecalc", cmdArgs...)

	output := formatOutput(stdout, stderr, exitCode)
	return textResult(output)
}

// handleA2WCRecalcDMS - Recalculate for Docker-Mailserver (sync)
func handleA2WCRecalcDMS(args map[string]any) ToolCallResult {
	var cmdArgs []string

	if dmsDir := getString(args, "dmsDir", ""); dmsDir != "" {
		cmdArgs = append(cmdArgs, dmsDir)
	}

	stdout, stderr, exitCode, _ := runSync("a2wcrecalc-dms", cmdArgs...)

	output := formatOutput(stdout, stderr, exitCode)
	return textResult(output)
}

// handleCheckJobStatus - Check async job status
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
		result.WriteString("\n\n⏳ Job still running. Check again in 30-60 seconds.")
	} else if status == JobStatusCompleted {
		result.WriteString("\n\n✅ Job completed successfully.")
	} else {
		result.WriteString("\n\n❌ Job failed. Review stderr for details.")
	}

	return textResult(result.String())
}

// formatOutput formats command output for display
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
