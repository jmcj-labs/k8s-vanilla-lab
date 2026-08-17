#!/usr/bin/env python3
# The witness VERDICT, extracted so it can be tested without a cluster
# (scripts/test-witness-verdict.sh). scripts/witness-traffic.sh invokes it.
import os, collections
# .strip() BEFORE splitting: with maxsplit the final field keeps the
# trailing newline, so "ok\n" != "ok" and every window failed. Caught by
# the negative tests, which is what they are for.
SERIES = os.environ["SERIES"]
if not os.path.exists(SERIES):
    # It failed closed already (traceback, rc=1), but a witness must say WHY.
    print("\u2717 VERDICT: the series file does not exist (%s) — there is no" % SERIES)
    print("  record of this window at all, so it cannot have passed")
    raise SystemExit(1)
raw = [l.strip().split(None, 3) for l in open(SERIES) if l.strip()]
kinds = collections.Counter()
first_fail = None
bad_records = 0
series = []
events = []
for parts in raw:
    if len(parts) < 4:
        # A malformed line is a record we cannot read. Counting it as a
        # failure kind was NOT enough: it never entered `series`, so it never
        # reached the sent-vs-successful comparison and the window still
        # passed. Same pattern as everything else this sprint — the finding
        # existed and did not change the outcome. It is now its own hard gate.
        bad_records += 1
        if first_fail is None:
            first_fail = ("?", "?", "unreadable-record")
        continue
    epoch, ts, proto, result = parts[0], parts[1], parts[2], parts[3]
    if proto == "event":
        events.append((ts, result))
        continue
    series.append((int(epoch), ts, proto, result))
    kinds[result if result == "ok" else result.split(":")[0]] += 1
    if result != "ok" and first_fail is None:
        first_fail = (ts, proto, result)

# A stalled loop leaves a hole in the timeline that no counter would show.
max_gap = 0
for a, b in zip(series, series[1:]):
    max_gap = max(max_gap, b[0] - a[0])

sent = len(series)
ok = kinds["ok"]
print("")
print("=== WITNESS WINDOW '%s' ===" % os.environ["LABEL"])
print("  endpoint : %s" % os.environ["ENDPOINT"])
print("  from     : %s" % os.environ["STARTED"])
print("  sent     : %d" % sent)
print("  successful: %d" % ok)
for k in ("transport", "timeout", "http", "grpc"):
    if kinds[k]:
        print("  %-9s: %d" % (k, kinds[k]))
print("")
for ts, what in events:
    print("  event    : %s %s" % (ts, what))
if max_gap:
    print("  max gap  : %ds between consecutive probes" % max_gap)
print("")
if bad_records:
    print("✗ VERDICT: %d record(s) in the series could not be read — the log of what" % bad_records)
    print("  happened is itself damaged, so no verdict can be given over it")
    raise SystemExit(1)
if sent == 0:
    print("✗ VERDICT: the window recorded NOTHING — a witness with no probes is not evidence")
    raise SystemExit(1)
GAP_LIMIT = int(os.environ.get("WITNESS_MAX_GAP", "60"))
if max_gap > GAP_LIMIT:
    print("✗ VERDICT: the timeline has a %ds hole (limit %ds) — the witness stalled and cannot" % (max_gap, GAP_LIMIT))
    print("  vouch for what happened inside it")
    raise SystemExit(1)
if ok == sent:
    print("✓ VERDICT: sent == successful (%d/%d) — the entry path never broke" % (ok, sent))
    raise SystemExit(0)
print("✗ VERDICT: %d of %d probes did NOT succeed" % (sent - ok, sent))
print("  first failure: %s %s %s" % first_fail)
raise SystemExit(1)
