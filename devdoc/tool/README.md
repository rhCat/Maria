# devdoc/tool — the Maria deployment config

Version-controlled because it wasn't. Every change to the cage, the secrets wiring and the governance
environment used to live only on one laptop; the two bugs in the old launch line below survived precisely
because nothing tracked them.

## Deploy

```sh
cd <repo root>
MARIA_GOVD_TOKEN=$(cat /Volumes/prod/cyberware/monitors/maria-govd-agent1.token) \
LOCAL_LLM_TOKEN=$(cat /Volumes/prod/hunyuan/localllmtk/laguna-s-2-1-nvfp4.token) \
LITELLM_MASTER_KEY=$(cat /opt/data/config.yaml-api-key)  \
MARIA_ED25519_KEY=$(cat /Volumes/prod/cyberware/maria/etc/agent-ed25519.key | tr -d '\n') \
  docker compose -f devdoc/tool/docker-compose.maria.yml up -d --build maria
```

Build contexts resolve **relative to the compose file**, so the file carries `../..` — the context is still
the repo root. Run it from anywhere.

## Four values that are easy to get wrong

1. **`MARIA_GOVD_TOKEN` is the PRINCIPAL token** — `monitors/maria-govd-agent1.token`. The compose header
   used to point at `maria/etc/monitor.token`, which is a *fleetdash monitor* token. Deploying with it makes
   every claim 401 → fail-closed, i.e. Maria silently blocked on every tool call.
2. **`LITELLM_MASTER_KEY` must match what Maria already sends.** `/opt/data/config.yaml` is on a persistent
   volume and holds the api key she uses; a freshly generated key desyncs her from the proxy
   (`HTTP 400: No connected db`). Read it from her config rather than minting one. It must also start `sk-`.
3. **`GOVD_AUTH_VERIFIER` must stay an env var**, never `govd.json` — the body entrypoint **regenerates that
   file on every boot** and silently wipes it. `principals.json` survives; `govd.json` does not.
4. **`MARIA_ED25519_KEY` is 64 hex chars.** Its public half is declared as `subject` on the node's
   `agent-1` principal; the private half never leaves the container's tmpfs.

## Rollback to the static bearer

`token_sha` is still on `agent-1`, so identity can be reverted without re-minting anything:

```sh
# on maria-govd: drop GOVD_AUTH_VERIFIER, and set on maria:
HERMES_GOVERN_AUTH_SCHEME=token
```

## Related

- `scripts/verify-maria-cage.sh` — proves the containment contract without building the image
- `devdoc/BREAKPOINT.md` — session state and the rest of the traps
- `docs/design/cyberware-governance-flow.md` — what cyberware governs, and what it does not
