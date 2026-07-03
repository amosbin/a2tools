package main

import (
	"bufio"
	"bytes"
	"io"
	"os/exec"
	"sync"
	"time"

	"github.com/google/uuid"
)

const (
	MaxOutputLines    = 50
	JobCleanupTimeout = 10 * time.Minute
)

type JobStatus string

const (
	JobStatusRunning   JobStatus = "running"
	JobStatusCompleted JobStatus = "completed"
	JobStatusFailed    JobStatus = "failed"
)

type Job struct {
	ID        string
	Cmd       *exec.Cmd
	Status    JobStatus
	ExitCode  int
	StartTime time.Time
	EndTime   time.Time

	mu           sync.Mutex
	outputLines  []string
	stderrBuffer bytes.Buffer
}

type JobManager struct {
	mu   sync.RWMutex
	jobs map[string]*Job
}

func NewJobManager() *JobManager {
	jm := &JobManager{
		jobs: make(map[string]*Job),
	}
	// Start cleanup goroutine
	go jm.cleanupLoop()
	return jm
}

// StartJob spawns a command asynchronously and returns a job ID
func (jm *JobManager) StartJob(name string, args ...string) (string, error) {
	jobID := uuid.New().String()

	cmd := exec.Command(name, args...)

	// Create pipes for stdout and stderr
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return "", err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return "", err
	}

	job := &Job{
		ID:          jobID,
		Cmd:         cmd,
		Status:      JobStatusRunning,
		StartTime:   time.Now(),
		outputLines: make([]string, 0, MaxOutputLines),
	}

	// Start the command
	if err := cmd.Start(); err != nil {
		return "", err
	}

	// Store job
	jm.mu.Lock()
	jm.jobs[jobID] = job
	jm.mu.Unlock()

	// Read stdout in background
	go job.readOutput(stdout)

	// Read stderr in background
	go func() {
		io.Copy(&job.stderrBuffer, stderr)
	}()

	// Wait for completion in background
	go func() {
		err := cmd.Wait()
		job.mu.Lock()
		job.EndTime = time.Now()
		if err != nil {
			job.Status = JobStatusFailed
			if exitErr, ok := err.(*exec.ExitError); ok {
				job.ExitCode = exitErr.ExitCode()
			} else {
				job.ExitCode = -1
			}
		} else {
			job.Status = JobStatusCompleted
			job.ExitCode = 0
		}
		job.mu.Unlock()
	}()

	return jobID, nil
}

// GetJob returns a job by ID
func (jm *JobManager) GetJob(jobID string) *Job {
	jm.mu.RLock()
	defer jm.mu.RUnlock()
	return jm.jobs[jobID]
}

// GetJobStatus returns the current status of a job
func (jm *JobManager) GetJobStatus(jobID string) (status JobStatus, exitCode int, output string, stderr string, found bool) {
	job := jm.GetJob(jobID)
	if job == nil {
		return "", 0, "", "", false
	}

	job.mu.Lock()
	defer job.mu.Unlock()

	// Join output lines
	var outputBuf bytes.Buffer
	for _, line := range job.outputLines {
		outputBuf.WriteString(line)
		outputBuf.WriteString("\n")
	}

	return job.Status, job.ExitCode, outputBuf.String(), job.stderrBuffer.String(), true
}

// readOutput reads stdout line by line and keeps the last MaxOutputLines
func (j *Job) readOutput(r io.Reader) {
	scanner := bufio.NewScanner(r)
	for scanner.Scan() {
		line := scanner.Text()
		j.mu.Lock()
		j.outputLines = append(j.outputLines, line)
		// Keep only last MaxOutputLines
		if len(j.outputLines) > MaxOutputLines {
			j.outputLines = j.outputLines[len(j.outputLines)-MaxOutputLines:]
		}
		j.mu.Unlock()
	}
}

// cleanupLoop removes completed jobs after JobCleanupTimeout
func (jm *JobManager) cleanupLoop() {
	ticker := time.NewTicker(1 * time.Minute)
	defer ticker.Stop()

	for range ticker.C {
		jm.mu.Lock()
		now := time.Now()
		for id, job := range jm.jobs {
			job.mu.Lock()
			if job.Status != JobStatusRunning && now.Sub(job.EndTime) > JobCleanupTimeout {
				delete(jm.jobs, id)
			}
			job.mu.Unlock()
		}
		jm.mu.Unlock()
	}
}
