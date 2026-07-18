#!/usr/bin/env bash
# Supervise a comunica-sparql-hdt-http endpoint. comunica runs a Node cluster whose
# primary never exits, so an exit-based loop cannot catch a worker that hangs
# without dying. This launches the server, waits for it to answer, then health-checks
# the SPARQL socket and restarts the whole comunica tree if it stops answering for
# FAIL_LIMIT consecutive checks. Args: <hdt-path> <port> [query-timeout-seconds].
set -u

HDT="$1"
PORT="$2"
QUERY_TIMEOUT="${3:-1800}"
BIN="${ENDPOINT_BIN:-comunica-sparql-hdt-http}"
STARTUP_MAX="${ENDPOINT_STARTUP_MAX:-300}"
CHECK_INTERVAL="${ENDPOINT_CHECK_INTERVAL:-20}"
FAIL_LIMIT="${ENDPOINT_FAIL_LIMIT:-3}"
URL="http://127.0.0.1:${PORT}/sparql?query=ASK%7B%3Fs%20%3Fp%20%3Fo%7D"

health() {
  curl -sf -m 10 -H 'Accept: application/sparql-results+json' "$URL" >/dev/null 2>&1
}

while true; do
  "$BIN" "hdt@${HDT}" -p "${PORT}" -t "${QUERY_TIMEOUT}" --lenient &
  cpid=$!

  waited=0
  up=0
  while kill -0 "$cpid" 2>/dev/null && [ "$waited" -lt "$STARTUP_MAX" ]; do
    if health; then up=1; break; fi
    sleep 5
    waited=$((waited + 5))
  done

  if [ "$up" -eq 1 ]; then
    echo "[supervisor] :${PORT} up after ${waited}s" >&2
    fails=0
    while kill -0 "$cpid" 2>/dev/null; do
      sleep "$CHECK_INTERVAL"
      if health; then
        fails=0
      else
        fails=$((fails + 1))
        echo "[supervisor] :${PORT} health fail ${fails}/${FAIL_LIMIT}" >&2
        [ "$fails" -ge "$FAIL_LIMIT" ] && break
      fi
    done
    echo "[supervisor] :${PORT} unhealthy, restarting" >&2
  else
    echo "[supervisor] :${PORT} did not start within ${STARTUP_MAX}s, restarting" >&2
  fi

  kill -9 "$cpid" 2>/dev/null
  pkill -9 -f "${BIN} hdt@${HDT} -p ${PORT}" 2>/dev/null
  sleep 3
done
