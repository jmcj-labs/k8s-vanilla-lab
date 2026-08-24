// Decision table for the readiness aggregator, executed rather than read.
//
// The four fail-closed paths named in the design are each a row here, plus
// the happy path as a CONTROL: a gate that always says 503 would pass every
// negative test and be useless, so the control row is what makes the rest
// mean something (INCIDENTS #19 — assert the positive, do not infer from
// silence).
package main

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// stub returns a server answering with the given status after the given delay.
func stub(status int, delay time.Duration) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if delay > 0 {
			time.Sleep(delay)
		}
		w.WriteHeader(status)
		_, _ = w.Write([]byte("stub\n"))
	}))
}

// deadURL returns a URL nothing is listening on: a port we bound and released.
func deadURL(t *testing.T) string {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("cannot reserve a port: %v", err)
	}
	addr := l.Addr().String()
	_ = l.Close()
	return "http://" + addr + "/healthz"
}

func TestReadinessDecisionTable(t *testing.T) {
	const timeout = 300 * time.Millisecond

	okAgent := stub(http.StatusOK, 0)
	okEnvoy := stub(http.StatusOK, 0)
	badAgent := stub(http.StatusServiceUnavailable, 0)
	badEnvoy := stub(http.StatusInternalServerError, 0)
	slowAgent := stub(http.StatusOK, 5*timeout) // answers 200, but far too late
	defer func() {
		for _, s := range []*httptest.Server{okAgent, okEnvoy, badAgent, badEnvoy, slowAgent} {
			s.Close()
		}
	}()

	cases := []struct {
		name     string
		agentURL string
		envoyURL string
		wantOK   bool
	}{
		// CONTROL: without this row the suite would pass on a gate wired to
		// always fail.
		{"happy-both-200", okAgent.URL, okEnvoy.URL, true},

		// FAIL-CLOSED 1: status != 200.
		{"agent-503", badAgent.URL, okEnvoy.URL, false},
		{"envoy-500", okAgent.URL, badEnvoy.URL, false},
		{"both-non-200", badAgent.URL, badEnvoy.URL, false},

		// FAIL-CLOSED 2: nothing listening (connection refused).
		{"agent-refused", deadURL(t), okEnvoy.URL, false},
		{"envoy-refused", okAgent.URL, deadURL(t), false},
		{"both-refused", deadURL(t), deadURL(t), false},

		// FAIL-CLOSED 3: answers 200 but after the timeout. A late yes is a no.
		{"agent-timeout", slowAgent.URL, okEnvoy.URL, false},

		// FAIL-CLOSED 4: a URL that cannot even be turned into a request.
		{"agent-unparseable", "://not a url", okEnvoy.URL, false},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			client := &http.Client{Timeout: timeout}
			ups := []upstream{
				{name: "agent", url: tc.agentURL, headers: map[string]string{"brief": "true"}},
				{name: "envoy", url: tc.envoyURL},
			}
			ctx, cancel := context.WithTimeout(context.Background(), timeout)
			defer cancel()

			got, results := checkAll(ctx, client, ups)
			if got != tc.wantOK {
				t.Fatalf("got ok=%v, want %v (results: %+v)", got, tc.wantOK, results)
			}
		})
	}
}

// An empty upstream list verifies NOTHING, so it must not be a pass. Without
// this, a misconfiguration that produced no upstreams would report ready.
func TestEmptyUpstreamsIsNotReady(t *testing.T) {
	ok, _ := checkAll(context.Background(), &http.Client{Timeout: time.Second}, nil)
	if ok {
		t.Fatal("an empty upstream list reported ready; nothing was verified")
	}
}

// The HTTP surface must map the verdict onto the status code the NLB reads.
func TestHandlerStatusCodes(t *testing.T) {
	up := stub(http.StatusOK, 0)
	down := stub(http.StatusServiceUnavailable, 0)
	defer up.Close()
	defer down.Close()

	for _, tc := range []struct {
		name     string
		envoyURL string
		want     int
	}{
		{"ready-is-200", up.URL, http.StatusOK},
		{"not-ready-is-503", down.URL, http.StatusServiceUnavailable},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := handler(&http.Client{Timeout: time.Second}, []upstream{
				{name: "agent", url: up.URL},
				{name: "envoy", url: tc.envoyURL},
			}, time.Second)
			rec := httptest.NewRecorder()
			h(rec, httptest.NewRequest(http.MethodGet, "/healthz", nil))
			if rec.Code != tc.want {
				t.Fatalf("got HTTP %d, want %d (body: %s)", rec.Code, tc.want, rec.Body.String())
			}
		})
	}
}

// The agent's own readinessProbe sends `brief: true`; ours must too, or we
// are asking a different question than Cilium answers for itself.
func TestAgentBriefHeaderIsSent(t *testing.T) {
	seen := make(chan string, 1)
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen <- r.Header.Get("brief")
		w.WriteHeader(http.StatusOK)
	}))
	defer s.Close()

	_, _ = checkAll(context.Background(), &http.Client{Timeout: time.Second},
		[]upstream{{name: "agent", url: s.URL, headers: map[string]string{"brief": "true"}}})

	select {
	case v := <-seen:
		if v != "true" {
			t.Fatalf("brief header was %q, want \"true\"", v)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("upstream was never called")
	}
}
