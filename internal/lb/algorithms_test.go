package lb

import (
	"testing"
)

// ---- helpers ------------------------------------------------------------

func makeBackend(id string, latency, cpu float64, conns int64) *Backend {
	b := &Backend{ID: id, Healthy: true, AvgLatencyMs: latency, CPUPercent: cpu}
	b.ActiveConns = conns
	return b
}

// ---- normalize ----------------------------------------------------------

func TestNormalize_AllEqual(t *testing.T) {
	out := normalize([]float64{5, 5, 5})
	for _, v := range out {
		if v != 0 {
			t.Errorf("all-equal normalize: want 0, got %f", v)
		}
	}
}

func TestNormalize_Range(t *testing.T) {
	out := normalize([]float64{0, 5, 10})
	want := []float64{0, 0.5, 1}
	for i, v := range out {
		if v != want[i] {
			t.Errorf("normalize[%d] = %f, want %f", i, v, want[i])
		}
	}
}

func TestNormalize_SingleValue(t *testing.T) {
	out := normalize([]float64{42})
	if out[0] != 0 {
		t.Errorf("single-value normalize: want 0, got %f", out[0])
	}
}

// ---- variance -----------------------------------------------------------

func TestVariance_Uniform(t *testing.T) {
	if v := variance([]float64{3, 3, 3}, 3); v != 0 {
		t.Errorf("uniform variance: want 0, got %f", v)
	}
}

func TestVariance_Known(t *testing.T) {
	// [2, 4, 4, 4, 5, 5, 7, 9], mean=5, variance=4
	vals := []float64{2, 4, 4, 4, 5, 5, 7, 9}
	got := variance(vals, float64(len(vals)))
	if got != 4.0 {
		t.Errorf("variance = %f, want 4.0", got)
	}
}

func TestVariance_TwoValues(t *testing.T) {
	// [0, 10], mean=5, variance=25
	got := variance([]float64{0, 10}, 2)
	if got != 25.0 {
		t.Errorf("variance = %f, want 25.0", got)
	}
}

// ---- round robin --------------------------------------------------------

func TestRoundRobin_Empty(t *testing.T) {
	s := &roundRobinSelector{}
	if s.Select(nil) != nil {
		t.Error("expected nil for empty backends")
	}
}

func TestRoundRobin_Cycles(t *testing.T) {
	s := &roundRobinSelector{}
	backends := []*Backend{
		makeBackend("b1", 0, 0, 0),
		makeBackend("b2", 0, 0, 0),
		makeBackend("b3", 0, 0, 0),
	}
	got := []string{
		s.Select(backends).ID,
		s.Select(backends).ID,
		s.Select(backends).ID,
		s.Select(backends).ID, // wraps back to first
	}
	want := []string{"b1", "b2", "b3", "b1"}
	for i, id := range got {
		if id != want[i] {
			t.Errorf("call %d: got %q, want %q", i, id, want[i])
		}
	}
}

func TestRoundRobin_Name(t *testing.T) {
	s := &roundRobinSelector{}
	if s.Name() != AlgoRoundRobin {
		t.Errorf("Name() = %q, want %q", s.Name(), AlgoRoundRobin)
	}
}

// ---- lowest latency -----------------------------------------------------

func TestLowestLatency_Empty(t *testing.T) {
	s := &lowestLatencySelector{}
	if s.Select(nil) != nil {
		t.Error("expected nil for empty backends")
	}
}

func TestLowestLatency_PicksLowest(t *testing.T) {
	s := &lowestLatencySelector{}
	backends := []*Backend{
		makeBackend("b1", 100, 0, 0),
		makeBackend("b2", 10, 0, 0),
		makeBackend("b3", 50, 0, 0),
	}
	if got := s.Select(backends).ID; got != "b2" {
		t.Errorf("Select() = %q, want %q", got, "b2")
	}
}

func TestLowestLatency_AllEqual(t *testing.T) {
	s := &lowestLatencySelector{}
	backends := []*Backend{
		makeBackend("b1", 50, 0, 0),
		makeBackend("b2", 50, 0, 0),
	}
	// Should return the first one when all equal
	if got := s.Select(backends).ID; got != "b1" {
		t.Errorf("Select() = %q, want %q", got, "b1")
	}
}

// ---- lowest CPU ---------------------------------------------------------

func TestLowestCPU_Empty(t *testing.T) {
	s := &lowestCPUSelector{}
	if s.Select(nil) != nil {
		t.Error("expected nil for empty backends")
	}
}

func TestLowestCPU_PicksLowest(t *testing.T) {
	s := &lowestCPUSelector{}
	backends := []*Backend{
		makeBackend("b1", 0, 80, 0),
		makeBackend("b2", 0, 20, 0),
		makeBackend("b3", 0, 50, 0),
	}
	if got := s.Select(backends).ID; got != "b2" {
		t.Errorf("Select() = %q, want %q", got, "b2")
	}
}

// ---- least connections --------------------------------------------------

func TestLeastConnections_Empty(t *testing.T) {
	s := &leastConnectionsSelector{}
	if s.Select(nil) != nil {
		t.Error("expected nil for empty backends")
	}
}

func TestLeastConnections_PicksLowest(t *testing.T) {
	s := &leastConnectionsSelector{}
	backends := []*Backend{
		makeBackend("b1", 0, 0, 5),
		makeBackend("b2", 0, 0, 1),
		makeBackend("b3", 0, 0, 3),
	}
	if got := s.Select(backends).ID; got != "b2" {
		t.Errorf("Select() = %q, want %q", got, "b2")
	}
}

// ---- intelligent / selectByWeightedScore --------------------------------

func TestIntelligent_Empty(t *testing.T) {
	s := newIntelligentSelector(defaultWeights)
	if s.Select(nil) != nil {
		t.Error("expected nil for empty backends")
	}
}

func TestIntelligent_PicksBestScore(t *testing.T) {
	s := newIntelligentSelector(intelligentWeights{Latency: 1, CPU: 0, Connections: 0})
	backends := []*Backend{
		makeBackend("b1", 100, 0, 0),
		makeBackend("b2", 10, 0, 0), // lowest latency → should win
		makeBackend("b3", 50, 0, 0),
	}
	if got := s.Select(backends).ID; got != "b2" {
		t.Errorf("Select() = %q, want %q", got, "b2")
	}
}

func TestIntelligent_AllEqual(t *testing.T) {
	s := newIntelligentSelector(defaultWeights)
	backends := []*Backend{
		makeBackend("b1", 50, 50, 5),
		makeBackend("b2", 50, 50, 5),
	}
	// All metrics equal → all normalized scores are 0 → first backend wins
	if got := s.Select(backends).ID; got != "b1" {
		t.Errorf("Select() = %q, want %q", got, "b1")
	}
}

func TestIntelligent_SetAndGetWeights(t *testing.T) {
	s := newIntelligentSelector(defaultWeights)
	w := intelligentWeights{Latency: 0.5, CPU: 0.3, Connections: 0.2}
	s.SetWeights(w)
	got := s.Weights()
	if got != w {
		t.Errorf("Weights() = %+v, want %+v", got, w)
	}
}

func TestSelectByWeightedScore_CPUOnly(t *testing.T) {
	w := intelligentWeights{Latency: 0, CPU: 1, Connections: 0}
	backends := []*Backend{
		makeBackend("b1", 0, 90, 0),
		makeBackend("b2", 0, 10, 0), // lowest CPU → should win
		makeBackend("b3", 0, 50, 0),
	}
	if got := selectByWeightedScore(backends, w).ID; got != "b2" {
		t.Errorf("selectByWeightedScore() = %q, want %q", got, "b2")
	}
}

// ---- adaptive -----------------------------------------------------------

func TestAdaptive_Name(t *testing.T) {
	a := newAdaptiveSelector(func() []*Backend { return nil })
	defer a.Stop()
	if a.Name() != AlgoAdaptive {
		t.Errorf("Name() = %q, want %q", a.Name(), AlgoAdaptive)
	}
}

func TestAdaptive_DefaultWeights(t *testing.T) {
	a := newAdaptiveSelector(func() []*Backend { return nil })
	defer a.Stop()
	if w := a.Weights(); w != defaultWeights {
		t.Errorf("initial weights = %+v, want %+v", w, defaultWeights)
	}
}

func TestAdaptive_RecomputeWeights_ShiftsToHighVariance(t *testing.T) {
	backends := []*Backend{
		makeBackend("b1", 10, 90, 0), // high CPU variance across b1/b2
		makeBackend("b2", 10, 10, 0), // latency equal → zero variance
	}
	a := newAdaptiveSelector(func() []*Backend { return backends })
	defer a.Stop()

	a.recomputeWeights()

	w := a.Weights()
	// CPU has all the variance; latency and connections have zero.
	if w.CPU != 1.0 {
		t.Errorf("CPU weight = %.4f, want 1.0 after all variance is in CPU", w.CPU)
	}
	if w.Latency != 0 || w.Connections != 0 {
		t.Errorf("non-CPU weights should be 0, got latency=%.4f conns=%.4f", w.Latency, w.Connections)
	}
}

func TestAdaptive_RecomputeWeights_NoChange_WhenUniform(t *testing.T) {
	backends := []*Backend{
		makeBackend("b1", 50, 50, 5),
		makeBackend("b2", 50, 50, 5),
	}
	a := newAdaptiveSelector(func() []*Backend { return backends })
	defer a.Stop()

	before := a.Weights()
	a.recomputeWeights() // all variance zero → weights unchanged
	after := a.Weights()

	if before != after {
		t.Errorf("weights changed despite uniform metrics: %+v → %+v", before, after)
	}
}

// ---- factory ------------------------------------------------------------

func TestNewSelector_AllNames(t *testing.T) {
	cases := []struct {
		name string
		want string
	}{
		{AlgoRoundRobin, AlgoRoundRobin},
		{AlgoLowestLatency, AlgoLowestLatency},
		{AlgoLowestCPU, AlgoLowestCPU},
		{AlgoLeastConnections, AlgoLeastConnections},
		{AlgoIntelligent, AlgoIntelligent},
		{AlgoAdaptive, AlgoAdaptive},
	}
	for _, tc := range cases {
		sel := NewSelector(tc.name, func() []*Backend { return nil })
		if a, ok := sel.(*adaptiveSelector); ok {
			a.Stop()
		}
		if sel.Name() != tc.want {
			t.Errorf("NewSelector(%q).Name() = %q, want %q", tc.name, sel.Name(), tc.want)
		}
	}
}

func TestNewSelector_UnknownFallsBackToRoundRobin(t *testing.T) {
	sel := NewSelector("bogus_algo", nil)
	if sel.Name() != AlgoRoundRobin {
		t.Errorf("unknown algo: got %q, want %q", sel.Name(), AlgoRoundRobin)
	}
}
