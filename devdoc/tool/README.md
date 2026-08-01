# devdoc/tool — the Maria deployment config

Version-controlled because it wasn't. Every change to the cage, the secrets wiring and the governance
environment used to live only on one laptop; the two bugs in the old launch line below survived precisely
because nothing tracked them.

## Deploy

```sh
cd <repo root>
MARIA_GOVD_TOKEN=$(cat /Volumes/prod/cyberware/monitors/maria-govd-agent1.token) \
LOCAL_LLM_TOKEN=$(cat /Volumes/prod/hunyuan/localllmtk/laguna-s-2-1-nvfp4.token) \
LITELLM_MASTER_KEY=$(docker exec maria sh -c 'grep -o "sk-[A-Za-z0-9_-]*" /opt/data/config.yaml | head -1') \
MARIA_ED25519_KEY=$(cat /Volumes/prod/cyberware/maria/etc/agent-ed25519.key | tr -d '\n') \
  docker compose -f devdoc/tool/docker-compose.maria.yml up -d --build maria
```

`/opt/data` is a path **inside the maria container**, not on the host — this line used to read
`cat /opt/data/config.yaml-api-key`, which resolves to nothing on the Mac. The failure is quiet in the way
that matters: `cat` errors, the var comes out empty, compose refuses the whole file with *"required variable
LITELLM_MASTER_KEY is missing a value"*, and **the running containers are left untouched and healthy**. It
looks exactly like a successful no-op deploy.

Build contexts resolve **relative to the compose file**, so the file carries `../..` — the context is still
the repo root. Run it from anywhere.

## Five things that are easy to get wrong

1. **`MARIA_GOVD_TOKEN` is the PRINCIPAL token** — `monitors/maria-govd-agent1.token`. The compose header
   used to point at `maria/etc/monitor.token`, which is a *fleetdash monitor* token. Deploying with it makes
   every claim 401 → fail-closed, i.e. Maria silently blocked on every tool call.
2. **`LITELLM_MASTER_KEY` must match what Maria already sends.** `/opt/data/config.yaml` is on a persistent
   volume **inside her container** and holds the api key she uses; a freshly generated key desyncs her from
   the proxy (`HTTP 400: No connected db`). Read it out of the running container (`docker exec maria …`, as
   above) rather than minting one, and never from a host path — there is no `/opt/data` on the Mac. It must
   also start `sk-`.

5. **`restart` is not `up -d`.** `docker restart maria-govd` (or `compose restart`) re-runs the *existing*
   container definition — it does not re-read this compose file and does not pull a newer image. The
   container comes back `healthy` having changed nothing, so a config edit appears to have deployed when it
   has not. Only `up -d` applies an edit; add `--force-recreate` to be sure and `--pull always` to take a new
   image. Check with `docker inspect maria-govd --format '{{json .Config.Cmd}}'` and `/health` — never with
   `docker ps`, which is green either way.
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
