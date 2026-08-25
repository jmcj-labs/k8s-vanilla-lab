// NOT DEPLOYED — kept as the record of an investigation, not as a component.
//
// The readiness aggregator was designed for a health check the NLB cannot
// perform in this topology: TCP is blind to Envoy, and the native HTTPS check
// cannot send the SNI/Host required by the Gateway listener.
// 4a therefore stopped relying on DETECTION and moved to proactive DRAINING
// (docs/RUNBOOK-upgrade-cilium-v3.md): the node leaves the pool before it is
// touched and returns only after it is proven to serve.
//
// What survives here is worth more than the binary: the comments below record
// what was proven from Cilium's own source — that the agent's /healthz does
// NOT cover NodePort datapath programming, and that Cilium's kube-proxy
// healthz "reasonably assumes" it. That is INCIDENTS #20. The drain runbook
// supersedes this component with a sustained HTTP+gRPC probation through the
// real NLB after each target is re-registered (step 2.8).
//
// Command node-readiness answers ONE question about the node it runs on:
// can this node serve Gateway traffic right now?
//
// WHY IT EXISTS. The NLB health-checks the Gateway target group with TCP on
// the NodePort. Cilium programs that NodePort from the agent's eBPF datapath
// regardless of whether the agent or the local Envoy can actually serve, so
// the check passes while the node is dead to traffic. That is how the 4a
// upgrade shut a third of the door with every target still reported healthy
// (INCIDENTS #20).
//
// Both components already expose HTTP /healthz — the agent on 9879, Envoy on
// 9878 — but BOTH BIND TO 127.0.0.1 ONLY, so the load balancer cannot reach
// them. This binds 0.0.0.0:9890, asks both over loopback, and answers with a
// single status the NLB can act on.
//
// THE RULE THIS OBEYS (INCIDENTS #17): fail closed, without exception. A
// readiness endpoint that answers 200 when it could not determine the answer
// keeps a node with a dead datapath in the load balancer's pool — which is
// precisely the failure it was built to prevent. Every uncertainty is 503.
package main

import (
	"context"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"sync"
	"time"
)

type upstream struct {
	name    string
	url     string
	headers map[string]string
}

// result of probing one upstream. ok is true ONLY on a clean HTTP 200.
type result struct {
	name   string
	ok     bool
	detail string
}

// probe performs one GET and reduces every possible outcome to ok/not-ok.
// There is deliberately no branch that returns ok on an error path.
func probe(ctx context.Context, c *http.Client, u upstream) result {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.url, nil)
	if err != nil {
		return result{u.name, false, "request build failed: " + err.Error()}
	}
	for k, v := range u.headers {
		req.Header.Set(k, v)
	}
	resp, err := c.Do(req)
	if err != nil {
		// Covers connection refused, DNS, and the client timeout alike. We do
		// not distinguish them in the verdict — all of them mean "cannot
		// confirm this node is serving".
		return result{u.name, false, "unreachable: " + err.Error()}
	}
	defer resp.Body.Close()

	// Drain with a cap so a hostile or wedged upstream cannot hold us open,
	// and so the connection can be reused. A read error is NOT a pass.
	if _, err := io.Copy(io.Discard, io.LimitReader(resp.Body, 64<<10)); err != nil {
		return result{u.name, false, fmt.Sprintf("read failed after HTTP %d: %v", resp.StatusCode, err)}
	}
	if resp.StatusCode != http.StatusOK {
		return result{u.name, false, fmt.Sprintf("HTTP %d", resp.StatusCode)}
	}
	return result{u.name, true, "HTTP 200"}
}

// checkAll probes every upstream concurrently and applies a STRICT AND.
// Concurrency keeps the worst case at one timeout rather than the sum, which
// matters when the health check interval is aggressive.
func checkAll(ctx context.Context, c *http.Client, ups []upstream) (bool, []result) {
	results := make([]result, len(ups))
	var wg sync.WaitGroup
	for i, u := range ups {
		wg.Add(1)
		go func(i int, u upstream) {
			defer wg.Done()
			results[i] = probe(ctx, c, u)
		}(i, u)
	}
	wg.Wait()

	// An empty upstream list must NOT be a pass: nothing was verified.
	if len(results) == 0 {
		return false, results
	}
	for _, r := range results {
		if !r.ok {
			return false, results
		}
	}
	return true, results
}

func handler(c *http.Client, ups []upstream, timeout time.Duration) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), timeout)
		defer cancel()

		ok, results := checkAll(ctx, c, ups)

		status := http.StatusServiceUnavailable
		if ok {
			status = http.StatusOK
		}
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		w.WriteHeader(status)

		// Body is for humans reading logs or curling by hand; the NLB only
		// reads the status code.
		if ok {
			fmt.Fprintln(w, "ready")
		} else {
			fmt.Fprintln(w, "not ready")
		}
		for _, res := range results {
			state := "FAIL"
			if res.ok {
				state = "ok"
			}
			fmt.Fprintf(w, "%-6s %-6s %s\n", res.name, state, res.detail)
		}
	}
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func main() {
	var (
		listen       = envOr("LISTEN_ADDR", ":9890")
		agentURL     = envOr("AGENT_HEALTH_URL", "http://127.0.0.1:9879/healthz")
		envoyURL     = envOr("ENVOY_HEALTH_URL", "http://127.0.0.1:9878/healthz")
		probeTimeout = 2 * time.Second
	)
	if v := os.Getenv("PROBE_TIMEOUT"); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil {
			log.Fatalf("PROBE_TIMEOUT %q is not a duration: %v", v, err)
		}
		probeTimeout = d
	}

	ups := []upstream{
		// `brief: true` mirrors Cilium's own readinessProbe: the short answer
		// about this agent, not a cluster-wide health survey that would make
		// one node's readiness depend on another's.
		{name: "agent", url: agentURL, headers: map[string]string{"brief": "true"}},
		{name: "envoy", url: envoyURL},
	}

	client := &http.Client{
		Timeout: probeTimeout,
		Transport: &http.Transport{
			DisableKeepAlives:   false,
			MaxIdleConnsPerHost: 2,
		},
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", handler(client, ups, probeTimeout))
	mux.HandleFunc("/", handler(client, ups, probeTimeout))

	// TIME BUDGET, and the ordering between these is the whole point:
	//
	//   probeTimeout (2s)  <  handlerBudget (5s)  <  WriteTimeout (8s)  <  HC interval (10s)
	//
	// The load balancer must never read "health check timed out" — that is
	// ambiguous, and an ambiguous answer during a rollout is what this whole
	// endpoint exists to eliminate. It must read a status code, and if the
	// node is not ready that code is 503.
	//
	// http.TimeoutHandler guarantees an answer within handlerBudget: if the
	// handler has not written by then it emits 503 itself. WriteTimeout sits
	// ABOVE it on purpose — if the server killed the connection first, the
	// 503 would never make it onto the wire and the client would see a
	// timeout, which is exactly the outcome being designed out.
	const (
		handlerBudget = 5 * time.Second
		writeTimeout  = 8 * time.Second
	)
	timed := http.TimeoutHandler(mux, handlerBudget,
		"not ready\nreadiness check exceeded its own deadline\n")

	srv := &http.Server{
		Addr:    listen,
		Handler: timed,
		// Headers: guards against a client that opens a connection and dribbles.
		ReadHeaderTimeout: 3 * time.Second,
		// Whole request. GETs here have no body, but bounding it costs nothing.
		ReadTimeout: 5 * time.Second,
		// THE ONE THAT WAS MISSING: a client that never reads the response
		// cannot hold a handler — and its goroutine and fd — open forever.
		WriteTimeout: writeTimeout,
		// Keep-alive connections must not accumulate either.
		IdleTimeout:    30 * time.Second,
		MaxHeaderBytes: 16 << 10,
	}
	log.Printf("node-readiness listening on %s (agent=%s envoy=%s timeout=%s)",
		listen, agentURL, envoyURL, probeTimeout)
	log.Fatal(srv.ListenAndServe())
}
