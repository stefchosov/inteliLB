package lb

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// ---- New ----------------------------------------------------------------

func TestNew_ValidConfig(t *testing.T) {
	b, err := New(Config{
		BackendURLs: []string{"http://localhost:8081", "http://localhost:8082"},
		Algorithm:   AlgoRoundRobin,
	})
	if err != nil {
		t.Fatalf("New() error = %v", err)
	}
	if len(b.backends) != 2 {
		t.Errorf("len(backends) = %d, want 2", len(b.backends))
	}
}

func TestNew_InvalidURL(t *testing.T) {
	// url.Parse is very permissive; an unparseable URL triggers the error path.
	_, err := New(Config{
		BackendURLs: []string{"://bad-url"},
	})
	if err == nil {
		t.Error("expected error for invalid URL, got nil")
	}
}

func TestNew_BackendsStartHealthy(t *testing.T) {
	b, _ := New(Config{BackendURLs: []string{"http://localhost:8081"}})
	for _, be := range b.backends {
		if !be.Healthy {
			t.Errorf("backend %s should start healthy (optimistic)", be.ID)
		}
	}
}

// ---- healthyBackends ----------------------------------------------------

func TestHealthyBackends_FiltersUnhealthy(t *testing.T) {
	b, _ := New(Config{BackendURLs: []string{
		"http://localhost:8081",
		"http://localhost:8082",
		"http://localhost:8083",
	}})
	b.backends[1].Healthy = false

	healthy := b.healthyBackends()
	if len(healthy) != 2 {
		t.Errorf("healthyBackends() = %d, want 2", len(healthy))
	}
}

func TestHealthyBackends_NoneHealthy(t *testing.T) {
	b, _ := New(Config{BackendURLs: []string{"http://localhost:8081"}})
	b.backends[0].Healthy = false

	if got := b.healthyBackends(); len(got) != 0 {
		t.Errorf("expected 0 healthy backends, got %d", len(got))
	}
}

func TestHealthyBackends_AllHealthy(t *testing.T) {
	b, _ := New(Config{BackendURLs: []string{
		"http://localhost:8081",
		"http://localhost:8082",
	}})
	if got := b.healthyBackends(); len(got) != 2 {
		t.Errorf("expected 2 healthy backends, got %d", len(got))
	}
}

// ---- SetAlgorithm / Algorithm -------------------------------------------

func TestSetAlgorithm_SwitchesCorrectly(t *testing.T) {
	b, _ := New(Config{
		BackendURLs: []string{"http://localhost:8081"},
		Algorithm:   AlgoRoundRobin,
	})

	for _, algo := range []string{
		AlgoLowestLatency, AlgoLowestCPU, AlgoLeastConnections,
		AlgoIntelligent, AlgoRoundRobin,
	} {
		b.SetAlgorithm(algo)
		if got := b.Algorithm(); got != algo {
			t.Errorf("after SetAlgorithm(%q): Algorithm() = %q", algo, got)
		}
	}
}

func TestSetAlgorithm_StopsAdaptive(t *testing.T) {
	b, _ := New(Config{
		BackendURLs: []string{"http://localhost:8081"},
		Algorithm:   AlgoAdaptive,
	})
	// Switching away from adaptive should not panic or block.
	b.SetAlgorithm(AlgoRoundRobin)
	if b.Algorithm() != AlgoRoundRobin {
		t.Error("expected round_robin after switching from adaptive")
	}
}

// ---- fetchMetrics -------------------------------------------------------

func TestFetchMetrics_UpdatesBackend(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{
			"cpu_percent":        55.5,
			"memory_percent":     30.0,
			"active_connections": int64(7),
		})
	}))
	defer srv.Close()

	b, _ := New(Config{BackendURLs: []string{srv.URL}})
	be := b.backends[0]

	b.fetchMetrics(be)

	be.mu.RLock()
	cpu := be.CPUPercent
	mem := be.MemPercent
	be.mu.RUnlock()

	if cpu != 55.5 {
		t.Errorf("CPUPercent = %.1f, want 55.5", cpu)
	}
	if mem != 30.0 {
		t.Errorf("MemPercent = %.1f, want 30.0", mem)
	}
	if be.ActiveConns != 7 {
		t.Errorf("ActiveConns = %d, want 7", be.ActiveConns)
	}
}

func TestFetchMetrics_HandlesError(t *testing.T) {
	b, _ := New(Config{BackendURLs: []string{"http://127.0.0.1:1"}}) // unreachable
	// Should return silently without panicking.
	b.fetchMetrics(b.backends[0])
}

func TestFetchMetrics_HandlesBadJSON(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("not json"))
	}))
	defer srv.Close()

	b, _ := New(Config{BackendURLs: []string{srv.URL}})
	// Should return silently without panicking.
	b.fetchMetrics(b.backends[0])
}

// ---- checkHealth --------------------------------------------------------

func TestCheckHealth_MarksHealthy(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	b, _ := New(Config{BackendURLs: []string{srv.URL}})
	be := b.backends[0]
	be.Healthy = false // start unhealthy

	b.checkHealth(be)

	be.mu.RLock()
	healthy := be.Healthy
	be.mu.RUnlock()

	if !healthy {
		t.Error("expected backend to be marked healthy after 200 response")
	}
}

func TestCheckHealth_MarksUnhealthy_On500(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()

	b, _ := New(Config{BackendURLs: []string{srv.URL}})
	be := b.backends[0]

	b.checkHealth(be)

	be.mu.RLock()
	healthy := be.Healthy
	be.mu.RUnlock()

	if healthy {
		t.Error("expected backend to be marked unhealthy after 500 response")
	}
}

func TestCheckHealth_MarksUnhealthy_OnConnectionRefused(t *testing.T) {
	b, _ := New(Config{BackendURLs: []string{"http://127.0.0.1:1"}})
	be := b.backends[0]

	b.checkHealth(be)

	be.mu.RLock()
	healthy := be.Healthy
	be.mu.RUnlock()

	if healthy {
		t.Error("expected backend to be marked unhealthy when connection refused")
	}
}

// ---- Stats --------------------------------------------------------------

func TestStats_ReturnsCorrectAlgorithm(t *testing.T) {
	b, _ := New(Config{
		BackendURLs: []string{"http://localhost:8081"},
		Algorithm:   AlgoLowestCPU,
	})
	s := b.Stats()
	if s.Algorithm != AlgoLowestCPU {
		t.Errorf("Stats().Algorithm = %q, want %q", s.Algorithm, AlgoLowestCPU)
	}
}

func TestStats_AllBackendsPresent(t *testing.T) {
	b, _ := New(Config{
		BackendURLs: []string{
			"http://localhost:8081",
			"http://localhost:8082",
			"http://localhost:8083",
		},
	})
	s := b.Stats()
	if len(s.Backends) != 3 {
		t.Errorf("Stats().Backends len = %d, want 3", len(s.Backends))
	}
}

func TestStats_TotalRequests(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	b, _ := New(Config{BackendURLs: []string{srv.URL}})

	req := httptest.NewRequest(http.MethodGet, "/", nil)
	rw := httptest.NewRecorder()
	b.ServeHTTP(rw, req)
	b.ServeHTTP(rw, req)

	s := b.Stats()
	if s.TotalRequests != 2 {
		t.Errorf("TotalRequests = %d, want 2", s.TotalRequests)
	}
}

// ---- ServeHTTP ----------------------------------------------------------

func TestServeHTTP_NoHealthyBackends(t *testing.T) {
	b, _ := New(Config{BackendURLs: []string{"http://localhost:8081"}})
	b.backends[0].Healthy = false

	req := httptest.NewRequest(http.MethodGet, "/", nil)
	rw := httptest.NewRecorder()
	b.ServeHTTP(rw, req)

	if rw.Code != http.StatusServiceUnavailable {
		t.Errorf("status = %d, want %d", rw.Code, http.StatusServiceUnavailable)
	}
}

func TestServeHTTP_ProxiesToBackend(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("pong"))
	}))
	defer srv.Close()

	b, _ := New(Config{BackendURLs: []string{srv.URL}})

	req := httptest.NewRequest(http.MethodGet, "/ping", nil)
	rw := httptest.NewRecorder()
	b.ServeHTTP(rw, req)

	if rw.Code != http.StatusOK {
		t.Errorf("status = %d, want %d", rw.Code, http.StatusOK)
	}
	if rw.Body.String() != "pong" {
		t.Errorf("body = %q, want %q", rw.Body.String(), "pong")
	}
}

// ---- Start / Stop -------------------------------------------------------

func TestStartStop_NoRace(t *testing.T) {
	b, _ := New(Config{
		BackendURLs:    []string{"http://localhost:8081"},
		PollInterval:   50 * time.Millisecond,
		HealthInterval: 50 * time.Millisecond,
	})
	b.Start()
	time.Sleep(60 * time.Millisecond)
	b.Stop()
	// If we reach here without a race or panic, the test passes.
}
