package lb

import (
	"math"
	"sync"
	"sync/atomic"
	"time"
)

// Algorithm names
const (
	AlgoRoundRobin       = "round_robin"
	AlgoLowestLatency    = "lowest_latency"
	AlgoLowestCPU        = "lowest_cpu"
	AlgoLeastConnections = "least_connections"
	AlgoIntelligent      = "intelligent"
	AlgoAdaptive         = "adaptive"
)

// intelligentWeights holds the three scoring weights used by intelligent/adaptive.
type intelligentWeights struct {
	Latency     float64
	CPU         float64
	Connections float64
}

var defaultWeights = intelligentWeights{Latency: 0.4, CPU: 0.4, Connections: 0.2}

// Selector picks a backend from a slice of healthy backends.
// All implementations must be safe for concurrent use.
type Selector interface {
	Select(backends []*Backend) *Backend
	Name() string
}

// ---- Round Robin --------------------------------------------------------

type roundRobinSelector struct {
	counter uint64
}

func (r *roundRobinSelector) Name() string { return AlgoRoundRobin }

func (r *roundRobinSelector) Select(backends []*Backend) *Backend {
	if len(backends) == 0 {
		return nil
	}
	idx := atomic.AddUint64(&r.counter, 1) - 1
	return backends[int(idx)%len(backends)]
}

// ---- Lowest Latency -----------------------------------------------------

type lowestLatencySelector struct{}

func (l *lowestLatencySelector) Name() string { return AlgoLowestLatency }

func (l *lowestLatencySelector) Select(backends []*Backend) *Backend {
	if len(backends) == 0 {
		return nil
	}
	best := backends[0]
	best.mu.RLock()
	bestLat := best.AvgLatencyMs
	best.mu.RUnlock()

	for _, b := range backends[1:] {
		b.mu.RLock()
		lat := b.AvgLatencyMs
		b.mu.RUnlock()
		if lat < bestLat {
			bestLat = lat
			best = b
		}
	}
	return best
}

// ---- Lowest CPU ---------------------------------------------------------

type lowestCPUSelector struct{}

func (l *lowestCPUSelector) Name() string { return AlgoLowestCPU }

func (l *lowestCPUSelector) Select(backends []*Backend) *Backend {
	if len(backends) == 0 {
		return nil
	}
	best := backends[0]
	best.mu.RLock()
	bestCPU := best.CPUPercent
	best.mu.RUnlock()

	for _, b := range backends[1:] {
		b.mu.RLock()
		cpu := b.CPUPercent
		b.mu.RUnlock()
		if cpu < bestCPU {
			bestCPU = cpu
			best = b
		}
	}
	return best
}

// ---- Least Connections --------------------------------------------------

type leastConnectionsSelector struct{}

func (l *leastConnectionsSelector) Name() string { return AlgoLeastConnections }

func (l *leastConnectionsSelector) Select(backends []*Backend) *Backend {
	if len(backends) == 0 {
		return nil
	}
	best := backends[0]
	bestConns := atomic.LoadInt64(&best.ActiveConns)

	for _, b := range backends[1:] {
		conns := atomic.LoadInt64(&b.ActiveConns)
		if conns < bestConns {
			bestConns = conns
			best = b
		}
	}
	return best
}

// ---- Intelligent --------------------------------------------------------

type intelligentSelector struct {
	mu      sync.RWMutex
	weights intelligentWeights
}

func newIntelligentSelector(w intelligentWeights) *intelligentSelector {
	return &intelligentSelector{weights: w}
}

func (s *intelligentSelector) Name() string { return AlgoIntelligent }

func (s *intelligentSelector) SetWeights(w intelligentWeights) {
	s.mu.Lock()
	s.weights = w
	s.mu.Unlock()
}

func (s *intelligentSelector) Weights() intelligentWeights {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.weights
}

func (s *intelligentSelector) Select(backends []*Backend) *Backend {
	if len(backends) == 0 {
		return nil
	}
	w := s.Weights()
	return selectByWeightedScore(backends, w)
}

// selectByWeightedScore normalises each metric across backends then picks
// the backend with the lowest combined weighted score (lower = better).
func selectByWeightedScore(backends []*Backend, w intelligentWeights) *Backend {
	n := len(backends)
	lats := make([]float64, n)
	cpus := make([]float64, n)
	conns := make([]float64, n)

	for i, b := range backends {
		b.mu.RLock()
		lats[i] = b.AvgLatencyMs
		cpus[i] = b.CPUPercent
		b.mu.RUnlock()
		conns[i] = float64(atomic.LoadInt64(&b.ActiveConns))
	}

	normLat := normalize(lats)
	normCPU := normalize(cpus)
	normConn := normalize(conns)

	bestScore := math.MaxFloat64
	var best *Backend
	for i, b := range backends {
		score := w.Latency*normLat[i] + w.CPU*normCPU[i] + w.Connections*normConn[i]
		if score < bestScore {
			bestScore = score
			best = b
		}
	}
	return best
}

// normalize returns values scaled to [0,1] across the slice.
// If all values are equal it returns all zeros.
func normalize(vals []float64) []float64 {
	min, max := vals[0], vals[0]
	for _, v := range vals[1:] {
		if v < min {
			min = v
		}
		if v > max {
			max = v
		}
	}
	out := make([]float64, len(vals))
	r := max - min
	if r == 0 {
		return out // all equal → all zero
	}
	for i, v := range vals {
		out[i] = (v - min) / r
	}
	return out
}

// ---- Adaptive -----------------------------------------------------------

type adaptiveSelector struct {
	intelligentSelector
	ticker   *time.Ticker
	stopChan chan struct{}
	backends func() []*Backend // closure to read current healthy backends
}

func newAdaptiveSelector(backendsFunc func() []*Backend) *adaptiveSelector {
	a := &adaptiveSelector{
		intelligentSelector: intelligentSelector{weights: defaultWeights},
		ticker:              time.NewTicker(30 * time.Second),
		stopChan:            make(chan struct{}),
		backends:            backendsFunc,
	}
	go a.adjustLoop()
	return a
}

func (a *adaptiveSelector) Name() string { return AlgoAdaptive }

func (a *adaptiveSelector) Stop() {
	close(a.stopChan)
	a.ticker.Stop()
}

// adjustLoop recomputes weights every 30s based on variance of each metric.
func (a *adaptiveSelector) adjustLoop() {
	for {
		select {
		case <-a.stopChan:
			return
		case <-a.ticker.C:
			a.recomputeWeights()
		}
	}
}

func (a *adaptiveSelector) recomputeWeights() {
	backends := a.backends()
	if len(backends) < 2 {
		return
	}

	n := float64(len(backends))
	lats := make([]float64, len(backends))
	cpus := make([]float64, len(backends))
	conns := make([]float64, len(backends))

	for i, b := range backends {
		b.mu.RLock()
		lats[i] = b.AvgLatencyMs
		cpus[i] = b.CPUPercent
		b.mu.RUnlock()
		conns[i] = float64(atomic.LoadInt64(&b.ActiveConns))
	}

	varLat := variance(lats, n)
	varCPU := variance(cpus, n)
	varConn := variance(conns, n)

	total := varLat + varCPU + varConn
	if total == 0 {
		return // no variance — keep existing weights
	}

	newW := intelligentWeights{
		Latency:     varLat / total,
		CPU:         varCPU / total,
		Connections: varConn / total,
	}
	a.SetWeights(newW)
}

func variance(vals []float64, n float64) float64 {
	var sum float64
	for _, v := range vals {
		sum += v
	}
	mean := sum / n
	var sq float64
	for _, v := range vals {
		d := v - mean
		sq += d * d
	}
	return sq / n
}

// ---- Factory ------------------------------------------------------------

// NewSelector constructs the named Selector. backendsFunc is used only by
// the adaptive algorithm to sample current healthy backend metrics.
func NewSelector(name string, backendsFunc func() []*Backend) Selector {
	switch name {
	case AlgoLowestLatency:
		return &lowestLatencySelector{}
	case AlgoLowestCPU:
		return &lowestCPUSelector{}
	case AlgoLeastConnections:
		return &leastConnectionsSelector{}
	case AlgoIntelligent:
		return newIntelligentSelector(defaultWeights)
	case AlgoAdaptive:
		return newAdaptiveSelector(backendsFunc)
	default: // round_robin
		return &roundRobinSelector{}
	}
}
