#!/bin/sh
# Usage: sh test-monitoring.sh
# Two things must already be running:
#   1. the website:      HOST=0.0.0.0 python3 server.py
#   2. the monitoring:   docker compose up -d
# Asks the website, Prometheus and Grafana questions with curl and checks the replies.

SITE="http://localhost:8000"
PROM="http://localhost:9090"
GRAFANA="http://localhost:3000"
FAILED=0

# check "<name>" "<address>" "<text that must appear in the reply>"
check() {
  reply=$(curl -s "$2")
  if echo "$reply" | grep -qF -- "$3"; then
    echo "PASS: $1"
  else
    echo "FAIL: $1 -> got '$reply', expected it to contain '$3'"
    FAILED=1
  fi
}

# counter "<result>"   prints the current number from /metrics, for example:
#   expo_calculations_total{result="ok"} 3   ->   3
counter() {
  curl -s "$SITE/metrics" | grep "^expo_calculations_total{result=\"$1\"}" | cut -d' ' -f2
}

# ---- Part 1: the website's /metrics page ----

check "metrics page loads"  "$SITE/metrics"  "expo_calculations_total"
check "metrics has timing"  "$SITE/metrics"  "expo_calculation_seconds_sum"

# Do one good and one bad calculation, then see if the right counter went up.
ok_before=$(counter ok)
error_before=$(counter error)
curl -s "$SITE/calculate?base=2&exponent=10" > /dev/null
curl -s "$SITE/calculate?base=abc&exponent=2" > /dev/null
ok_after=$(counter ok)
error_after=$(counter error)

if [ "$ok_after" -eq $((ok_before + 1)) ]; then
  echo "PASS: ok counter went up by 1"
else
  echo "FAIL: ok counter was $ok_before, now $ok_after (expected +1)"
  FAILED=1
fi

if [ "$error_after" -eq $((error_before + 1)) ]; then
  echo "PASS: error counter went up by 1"
else
  echo "FAIL: error counter was $error_before, now $error_after (expected +1)"
  FAILED=1
fi

# ---- Part 2: Prometheus ----

check "Prometheus is ready"  "$PROM/-/ready"  "Ready"

# Prometheus needs a few seconds for its first scrape, so try up to 30 times.
# A reply with "1" in it means: up{job="expo-website"} = 1 (the website answers)
for i in $(seq 1 30); do
  reply=$(curl -s -G "$PROM/api/v1/query" --data-urlencode 'query=up{job="expo-website"}')
  echo "$reply" | grep -qF '"1"]' && break
  sleep 1
done
if echo "$reply" | grep -qF '"1"]'; then
  echo "PASS: Prometheus can reach the website (up = 1)"
else
  echo "FAIL: Prometheus cannot reach the website -> got '$reply'"
  FAILED=1
fi

check "alert rules are loaded"  "$PROM/api/v1/rules"  "ExpoWebsiteDown"

# ---- Part 3: Grafana ----

check "Grafana is healthy"        "$GRAFANA/api/health"                   "\"database\": \"ok\""
check "Grafana knows Prometheus"  "$GRAFANA/api/datasources"              "\"type\":\"prometheus\""
check "dashboard is loaded"       "$GRAFANA/api/search?query=Expo"        "Expo Calculator"

if [ "$FAILED" -eq 0 ]; then
  echo "All monitoring tests passed"
else
  echo "Some monitoring tests failed"
fi
exit $FAILED
