#!/usr/bin/env bash
# verify-maria-cage.sh — prove the containment of docker-compose.maria.yml
# WITHOUT building the (15-45 min) hermes image.
#
# Brings up the govd-proxy from the real compose file, then attaches a
# throwaway alpine to Maria's `cage` network as a stand-in for Maria and
# asserts what the cage does and does not permit. Exit code is the verdict.
set -uo pipefail

COMPOSE="${COMPOSE:-$(dirname "$0")/../docker-compose.maria.yml}"
GOVD_HOST="${GOVD_HOST:-100.101.222.80}"
# Upstream inference host, reached only via llm-proxy. Used here to assert the
# cage CANNOT reach it directly.
LLM_HOST="${LLM_HOST:-100.74.54.74}"
LLM_PORT="${LLM_PORT:-8081}"
PASS=0; FAIL=0

check() { # check <expect: ok|blocked> <name> <cmd...>
  local expect="$1" name="$2"; shift 2
  if "$@" >/dev/null 2>&1; then got=ok; else got=blocked; fi
  if [ "$got" = "$expect" ]; then
    printf '  PASS  %-46s (%s)\n' "$name" "$got"; PASS=$((PASS+1))
  else
    printf '  FAIL  %-46s (want %s, got %s)\n' "$name" "$expect" "$got"; FAIL=$((FAIL+1))
  fi
}

# A throwaway container on Maria's cage, standing in for Maria.
in_cage() { docker run --rm --network maria_cage alpine:latest "$@"; }

echo "== bringing up the cage (proxies only, not maria) =="
: "${LOCAL_LLM_TOKEN:?export LOCAL_LLM_TOKEN before running (see compose header)}"
export MARIA_GOVD_TOKEN="${MARIA_GOVD_TOKEN:-cage-verify}"
export LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY:-cage-verify}"
docker compose -f "$COMPOSE" up -d govd-proxy llm-proxy >/dev/null 2>&1 || {
  echo "could not start proxies"; exit 2; }
# Wait on the compose healthchecks rather than sleeping blind.
for _ in $(seq 1 90); do
  g=$(docker inspect -f '{{.State.Health.Status}}' maria-govd-proxy 2>/dev/null)
  l=$(docker inspect -f '{{.State.Health.Status}}' maria-llm-proxy 2>/dev/null)
  [ "$g" = healthy ] && [ "$l" = healthy ] && break
  sleep 2
done
echo "   govd-proxy=$g  llm-proxy=$l"

echo "== what the cage BLOCKS =="
check blocked "public internet by DNS name"      in_cage wget -q -T 5 -O /dev/null https://example.com
check blocked "public internet by raw IP"        in_cage wget -q -T 5 -O /dev/null http://1.1.1.1
check blocked "govd direct (no route off host)"  in_cage wget -q -T 5 -O /dev/null "http://${GOVD_HOST}:5773/catalog"
check blocked "fleet discovery plane :8773"      in_cage wget -q -T 5 -O /dev/null "http://${GOVD_HOST}:8773/fleet/health"
check blocked "sibling container on bridge"      in_cage wget -q -T 5 -O /dev/null http://172.17.0.2:5773/catalog
# The uplink CAN reach this over tailscale (docker desktop NATs container egress
# through the host, which is a tailnet member) -- that is how llm-proxy works.
# The cage must not.
check blocked "local LLM direct (tailnet peer)"  in_cage wget -q -T 5 -O /dev/null "http://${LLM_HOST}:${LLM_PORT}/v1/models"

echo "== what the cage ALLOWS (these two holes, and nothing else) =="
check ok      "govd /catalog via govd-proxy"     in_cage wget -q -T 5 -O /dev/null http://govd-proxy:5773/catalog
check ok      "inference via llm-proxy"          in_cage wget -q -T 5 -O /dev/null http://llm-proxy:4000/health/liveliness

echo "== compose declares no host bind mounts =="
# Parsed, not grepped: a regex over the raw file false-positives on any list
# item starting with '/', e.g. the `- /bin/sh` entrypoint.
if MARIA_GOVD_TOKEN=cage-verify docker compose -f "$COMPOSE" config --format json 2>/dev/null | python3 -c '
import json, sys
bad = []
svcs = json.load(sys.stdin).get("services", {})
for name, s in svcs.items():
    for v in s.get("volumes", []) or []:
        src = v.get("source", "") if isinstance(v, dict) else str(v).split(":")[0]
        if (v.get("type") if isinstance(v, dict) else "") == "bind" or src.startswith(("/", "~", ".")):
            bad.append(f"{name}: bind {src}")
    if s.get("network_mode") == "host":
        bad.append(f"{name}: network_mode host")
    if s.get("privileged"):
        bad.append(f"{name}: privileged")
print("\n".join(bad))
sys.exit(1 if bad else 0)
'; then
  echo "  PASS  no host paths, no docker socket, no host networking"; PASS=$((PASS+1))
else
  echo "  FAIL  containment violation above"; FAIL=$((FAIL+1))
fi

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
