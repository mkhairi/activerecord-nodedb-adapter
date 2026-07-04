# BUG-034: transient "Password authentication failed" under rapid connection churn

## Status: OPEN (2026-07-04) — observed on `67c4572d` and `f8a4df44` (v0.3.0 main head)

## Summary

Bursts of rapid sequential connection attempts (each opening a fresh
session, authenticating, running one statement, disconnecting) start
failing with:

```
FATAL:  Password authentication failed for user "nodedb"
```

The password is correct — the same credentials succeed a second or so
later with no intervention. The daemon logs nothing for the failed
attempts. Long-lived connections are unaffected (pooled ActiveRecord
suites hammer the daemon harder and never hit it); only the
connect/auth path flaps.

Auth-lockout settings are not involved: the dev daemon runs with
`max_failed_logins = 0`, `lockout_duration_secs = 0`,
`max_connections_per_user = 0`.

## Reproduction (shell, port 6432)

```bash
# each psql is a fresh connection; a burst of ~5-10 in quick
# succession reliably trips it
for i in $(seq 1 10); do
  psql -h localhost -p 6432 -U nodedb -d nodedb -tAc "SELECT 1"
done
# ... first few succeed, then:
# psql: error: ... FATAL:  Password authentication failed for user "nodedb"
# retrying after ~1s succeeds
```

Observed identically on the native transport (connection setup fails
the same way under churn).

## Impact

- Scripted retests / CI-style workloads that shell out one psql per
  statement fail intermittently mid-run.
- Any client without connection retry sees spurious auth errors that
  are indistinguishable from a wrong password.
- Two adapter spec-suite runs flapped this way (25/15 failures) and
  passed clean after the daemon settled — pure noise, expensive to
  diagnose.

## Workaround

Retry the connection after ~1s (scripted probes here wrap psql in an
`until` loop). Pooled long-lived connections avoid it entirely.

## Upstream fix sketch

Likely contention or a nonce/verifier race in the password-auth path
when handshakes overlap or arrive back-to-back; the failure being
unlogged makes it look like a rejected credential rather than a
transient internal error. At minimum the daemon should log the real
reason; ideally the auth path serializes or retries internally.

## Upstream

Not yet reported upstream.
