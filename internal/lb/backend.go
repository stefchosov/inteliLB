package lb

import (
	"sync"
	"sync/atomic"
)

const latencyHistorySize = 10

// Backend holds state for a single upstream backend server.
type Backend struct {
	ID     string
	URL    string
	Region string

	Healthy bool

	CPUPercent  float64
	MemPercent  float64
	ActiveConns int64

	AvgLatencyMs   float64
	LatencyHistory []float64

	TotalRequests  int64
	FailedRequests int64

	mu sync.RWMutex
}

// RecordLatency adds a new RTT sample and recomputes the rolling average.
func (b *Backend) RecordLatency(ms float64) {
	b.mu.Lock()
	defer b.mu.Unlock()

	b.LatencyHistory = append(b.LatencyHistory, ms)
	if len(b.LatencyHistory) > latencyHistorySize {
		b.LatencyHistory = b.LatencyHistory[len(b.LatencyHistory)-latencyHistorySize:]
	}

	var sum float64
	for _, v := range b.LatencyHistory {
		sum += v
	}
	b.AvgLatencyMs = sum / float64(len(b.LatencyHistory))
}

// IncrConns atomically increments the active connection counter.
func (b *Backend) IncrConns() {
	atomic.AddInt64(&b.ActiveConns, 1)
}

// DecrConns atomically decrements the active connection counter.
func (b *Backend) DecrConns() {
	atomic.AddInt64(&b.ActiveConns, -1)
}

// Stats returns a read-safe snapshot of the backend's metrics.
func (b *Backend) Stats() BackendStats {
	b.mu.RLock()
	defer b.mu.RUnlock()

	return BackendStats{
		ID:             b.ID,
		URL:            b.URL,
		Region:         b.Region,
		Healthy:        b.Healthy,
		CPUPercent:     b.CPUPercent,
		MemPercent:     b.MemPercent,
		ActiveConns:    atomic.LoadInt64(&b.ActiveConns),
		AvgLatencyMs:   b.AvgLatencyMs,
		TotalRequests:  atomic.LoadInt64(&b.TotalRequests),
		FailedRequests: atomic.LoadInt64(&b.FailedRequests),
	}
}

// BackendStats is a serialisable snapshot of a Backend.
type BackendStats struct {
	ID             string  `json:"id"`
	URL            string  `json:"url"`
	Region         string  `json:"region"`
	Healthy        bool    `json:"healthy"`
	CPUPercent     float64 `json:"cpu_percent"`
	MemPercent     float64 `json:"mem_percent"`
	ActiveConns    int64   `json:"active_connections"`
	AvgLatencyMs   float64 `json:"avg_latency_ms"`
	TotalRequests  int64   `json:"total_requests"`
	FailedRequests int64   `json:"failed_requests"`
}
