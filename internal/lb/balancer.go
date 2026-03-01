package lb

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"sync"
	"sync/atomic"
	"time"
)

// Balancer is the core load balancer: it proxies requests and manages backends.
type Balancer struct {
	mu            sync.RWMutex
	backends      []*Backend
	selector      Selector
	totalRequests int64

	pollInterval  time.Duration
	healthInterval time.Duration
	stopChan      chan struct{}
}

// Config holds Balancer construction options.
type Config struct {
	BackendURLs     []string
	Algorithm       string
	PollInterval    time.Duration
	HealthInterval  time.Duration
}

// New constructs a Balancer from the given config.
func New(cfg Config) (*Balancer, error) {
	if cfg.PollInterval == 0 {
		cfg.PollInterval = 5 * time.Second
	}
	if cfg.HealthInterval == 0 {
		cfg.HealthInterval = 5 * time.Second
	}

	b := &Balancer{
		pollInterval:   cfg.PollInterval,
		healthInterval: cfg.HealthInterval,
		stopChan:       make(chan struct{}),
	}

	for i, rawURL := range cfg.BackendURLs {
		parsed, err := url.Parse(rawURL)
		if err != nil {
			return nil, fmt.Errorf("invalid backend URL %q: %w", rawURL, err)
		}
		_ = parsed
		b.backends = append(b.backends, &Backend{
			ID:      fmt.Sprintf("backend-%d", i+1),
			URL:     rawURL,
			Healthy: true, // optimistic until first health check
		})
	}

	b.selector = NewSelector(cfg.Algorithm, b.healthyBackends)
	return b, nil
}

// Start launches the background polling goroutines.
func (b *Balancer) Start() {
	go b.pollMetricsLoop()
	go b.healthCheckLoop()
}

// Stop signals background goroutines to exit.
func (b *Balancer) Stop() {
	close(b.stopChan)
}

// SetAlgorithm hot-swaps the selection algorithm.
func (b *Balancer) SetAlgorithm(name string) {
	// Stop adaptive if currently running
	b.mu.Lock()
	if a, ok := b.selector.(*adaptiveSelector); ok {
		a.Stop()
	}
	b.selector = NewSelector(name, b.healthyBackends)
	b.mu.Unlock()
}

// Algorithm returns the current algorithm name.
func (b *Balancer) Algorithm() string {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return b.selector.Name()
}

// ServeHTTP implements http.Handler, proxying requests to a chosen backend.
func (b *Balancer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	backend := b.pick()
	if backend == nil {
		http.Error(w, "no healthy backends", http.StatusServiceUnavailable)
		return
	}

	target, _ := url.Parse(backend.URL)
	proxy := httputil.NewSingleHostReverseProxy(target)

	// Wrap the response writer to capture the status code for error tracking.
	rw := &responseWriter{ResponseWriter: w, statusCode: http.StatusOK}

	backend.IncrConns()
	atomic.AddInt64(&backend.TotalRequests, 1)
	atomic.AddInt64(&b.totalRequests, 1)

	start := time.Now()
	proxy.ErrorHandler = func(w http.ResponseWriter, req *http.Request, err error) {
		log.Printf("proxy error to %s: %v", backend.URL, err)
		atomic.AddInt64(&backend.FailedRequests, 1)
		http.Error(w, "bad gateway", http.StatusBadGateway)
	}
	proxy.ServeHTTP(rw, r)

	elapsed := float64(time.Since(start).Milliseconds())
	backend.RecordLatency(elapsed)
	backend.DecrConns()

	if rw.statusCode >= 500 {
		atomic.AddInt64(&backend.FailedRequests, 1)
	}
}

// pick selects a healthy backend using the active algorithm.
func (b *Balancer) pick() *Backend {
	healthy := b.healthyBackends()
	if len(healthy) == 0 {
		return nil
	}
	b.mu.RLock()
	sel := b.selector
	b.mu.RUnlock()
	return sel.Select(healthy)
}

// healthyBackends returns the subset of backends currently marked healthy.
func (b *Balancer) healthyBackends() []*Backend {
	b.mu.RLock()
	defer b.mu.RUnlock()
	var out []*Backend
	for _, be := range b.backends {
		be.mu.RLock()
		ok := be.Healthy
		be.mu.RUnlock()
		if ok {
			out = append(out, be)
		}
	}
	return out
}

// --- Background loops ----------------------------------------------------

func (b *Balancer) pollMetricsLoop() {
	ticker := time.NewTicker(b.pollInterval)
	defer ticker.Stop()
	for {
		select {
		case <-b.stopChan:
			return
		case <-ticker.C:
			b.mu.RLock()
			backends := make([]*Backend, len(b.backends))
			copy(backends, b.backends)
			b.mu.RUnlock()
			for _, be := range backends {
				go b.fetchMetrics(be)
			}
		}
	}
}

func (b *Balancer) healthCheckLoop() {
	ticker := time.NewTicker(b.healthInterval)
	defer ticker.Stop()
	for {
		select {
		case <-b.stopChan:
			return
		case <-ticker.C:
			b.mu.RLock()
			backends := make([]*Backend, len(b.backends))
			copy(backends, b.backends)
			b.mu.RUnlock()
			for _, be := range backends {
				go b.checkHealth(be)
			}
		}
	}
}

func (b *Balancer) fetchMetrics(be *Backend) {
	client := &http.Client{Timeout: 3 * time.Second}
	resp, err := client.Get(be.URL + "/metrics")
	if err != nil {
		return
	}
	defer resp.Body.Close()

	var m struct {
		CPUPercent  float64 `json:"cpu_percent"`
		MemPercent  float64 `json:"memory_percent"`
		ActiveConns int64   `json:"active_connections"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&m); err != nil {
		return
	}

	be.mu.Lock()
	be.CPUPercent = m.CPUPercent
	be.MemPercent = m.MemPercent
	be.mu.Unlock()
	atomic.StoreInt64(&be.ActiveConns, m.ActiveConns)
}

func (b *Balancer) checkHealth(be *Backend) {
	client := &http.Client{Timeout: 3 * time.Second}
	resp, err := client.Get(be.URL + "/health")

	be.mu.Lock()
	if err != nil || resp.StatusCode != http.StatusOK {
		if be.Healthy {
			log.Printf("backend %s marked unhealthy", be.ID)
		}
		be.Healthy = false
	} else {
		if !be.Healthy {
			log.Printf("backend %s recovered", be.ID)
		}
		be.Healthy = true
	}
	be.mu.Unlock()

	if resp != nil {
		io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
	}
}

// --- Stats ---------------------------------------------------------------

// StatsResponse is the JSON body for GET /lb/stats.
type StatsResponse struct {
	Algorithm     string         `json:"algorithm"`
	TotalRequests int64          `json:"total_requests"`
	Backends      []BackendStats `json:"backends"`
}

// Stats returns a snapshot of balancer metrics.
func (b *Balancer) Stats() StatsResponse {
	b.mu.RLock()
	algo := b.selector.Name()
	backends := make([]*Backend, len(b.backends))
	copy(backends, b.backends)
	b.mu.RUnlock()

	stats := make([]BackendStats, len(backends))
	for i, be := range backends {
		stats[i] = be.Stats()
	}
	return StatsResponse{
		Algorithm:     algo,
		TotalRequests: atomic.LoadInt64(&b.totalRequests),
		Backends:      stats,
	}
}

// --- Helper --------------------------------------------------------------

type responseWriter struct {
	http.ResponseWriter
	statusCode int
}

func (rw *responseWriter) WriteHeader(code int) {
	rw.statusCode = code
	rw.ResponseWriter.WriteHeader(code)
}
