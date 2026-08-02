# SOP — operating the Maria container

Day-two operations: storage, access, lifecycle, scratch space, backup. For
first-time setup see [`SETUP-SOP.md`](SETUP-SOP.md); for what the gate enforces
see [`GOVERNANCE.md`](GOVERNANCE.md).

---

## The storage model

Everything the agent accumulates lives in **one** Docker volume. There is no
per-subsystem mount.

| path | backing | survives recreate | notes |
|---|---|---|---|
| `/opt/data` | volume `maria_state` | **yes** | HERMES_HOME — the whole agent |
| `/opt/logs` | volume `maria_logs` | yes | explicitly disposable |
| `/opt/work` | volume or bind (optional) | yes | scratch; see below |
| `/run/maria` | **tmpfs** | **no** | credentials, re-injected each start |
| `/opt/hermes` | image layer | n/a | code — root-owned, read-only to the agent |

`/opt/data` holds `memories/`, `skills/`, `sessions/`, `cron/`, `platforms/`,
`plans/`, `sandboxes/`, `workspace/`, plus `state.db`, `kanban.db`,
`projects.db` and `config.yaml` (provider auth). A representative install is
~14 MB, of which `skills/` is ~11 MB.

**It is deliberately not a host bind mount.** From the compose:

> NO host bind mounts. Upstream mounts `~/.hermes:/opt/data`; here `/opt/data`
> is Docker-managed, no host path.

A bind would put the agent's writes into the host filesystem *and* make anything
in that directory reachable by an agent holding an `exec` perk. The named volume
keeps the agent's world a blob with no host path.

`/opt/hermes` being root-owned and unwritable by uid 10000 is **H2** — the agent
can accumulate memories and skills freely without ever being able to modify the
gate that governs it. Note `skills/` *is* agent-writable: skills there are data
the model reads, never code the gate trusts.

---

## Access

```
docker exec -it -u hermes maria /opt/hermes/bin/hermes --tui     # TUI
docker exec -it -u hermes maria /opt/hermes/bin/hermes chat      # plain CLI
docker exec    -u hermes maria /opt/hermes/bin/hermes -z "..."   # one-shot
docker exec -it -u hermes maria /opt/hermes/bin/hermes setup model
```

**Always `-u hermes`.** `docker exec` defaults to root, which creates root-owned
files under `/opt/data` that the agent then cannot write, and tests with
permissions the agent does not have — masking exactly the failures you are
looking for.

No ports are published; `docker exec` is the only surface. The gateway is
separately reachable if messaging platforms are configured.

---

## Lifecycle

Recreate freely — `--force-recreate` swaps the container and leaves the volume,
so memories, skills, sessions, cron and provider auth all survive. Sign-in is
once, not per-recreate.

**But `/run/maria` is tmpfs**, so the govd credential is wiped on every stop and
re-injected from the launch environment. Every launch line must therefore supply
`MARIA_GOVD_TOKEN` (and `MARIA_ED25519_KEY` under the signed scheme) — a
recreate without them comes up with no credential at all, and the agent
fail-closes on every tool call.

Destroying state takes an explicit `docker volume rm maria_state` or
`docker compose down -v`. Neither happens by accident.

---

## Scratch space

The agent will reach for `/tmp`, which is writable but sits on the container's
**overlay** filesystem: work there is lost on recreate and grows the container's
writable layer rather than storage you manage.

Give it a real one. `HERMES_WRITE_SAFE_ROOT` accepts multiple roots separated by
`os.pathsep`, so this extends the boundary rather than removing it:

```yaml
services:
  maria:
    volumes:
      - /data/maria/work:/opt/work        # or a named volume
    environment:
      HERMES_WRITE_SAFE_ROOT: "/opt/data:/opt/work"
      TMPDIR: "/opt/work/tmp"
```

```
sudo mkdir -p /data/maria/work/tmp && sudo chown -R 10000:10000 /data/maria/work
```

The `chown` is not optional — a fresh volume or directory is root-owned and the
agent is uid 10000, so it would be read-only to Hermes.

Keeping scratch separate from `/opt/data` also keeps backups lean: a multi-GB
build tree does not belong in a nightly state snapshot.

**A bind mount is defensible for scratch** — it is an empty directory only the
agent uses, exposing nothing pre-existing — in a way it is not for `/opt/data`.

Note this widens what the agent writes **without a governance claim**:
`HERMES_WRITE_SAFE_ROOT` is Hermes' own file-safety floor, beneath the gate. The
gate still classifies every `write_file` as a `write` perk. Keep `/opt/work`
narrow; do not mount pre-existing host content into it.

---

## Backup

One volume, so one archive. Stop the container first: `state.db`, `kanban.db`
and `projects.db` are SQLite with a live `-wal`, and a hot `tar` can capture a
torn write that restores to a corrupt database.

```
docker stop maria
docker run --rm -v maria_state:/src:ro -v "$PWD":/dst alpine \
    tar czf /dst/maria-state-$(date -u +%Y%m%dT%H%M%SZ).tar.gz -C /src .
docker start maria
```

Restore replaces everything — memories, skills, sessions, auth:

```
docker stop maria
docker run --rm -v maria_state:/dst -v "$PWD":/src:ro alpine \
    sh -c 'rm -rf /dst/* /dst/.[!.]* 2>/dev/null; tar xzf /src/<archive>.tar.gz -C /dst'
docker start maria
```

A ~14 MB volume compresses to ~5 MB, so nightly retention is cheap. The
`maria-*` shell helpers wrap both with pruning and a typed confirmation.

**Backups deliberately exclude credentials.** `/run/maria` is tmpfs and never
enters the archive; restoring gives you state, and the govd credential still
comes from the launch environment. That split is correct — keep it.

---

## Relocating Docker storage

If the goal is "all Docker storage on the big disk" rather than "the agent's
scratch on the big disk", do not bind-mount `/opt/data`. Set `data-root` to
`/data/docker` in `/etc/docker/daemon.json` and restart the daemon: every volume
moves, named-volume isolation is preserved, and no compose change is needed. It
bounces every container on the host, so treat it as a maintenance window.

---

## Quick reference

```
maria-vol            size + largest subdirs, without entering the container
maria-backup         stop -> snapshot -> restart, prunes to MARIA_BACKUP_KEEP
maria-backups        list archives
maria-restore FILE   destructive; requires typing RESTORE
maria-vol-sh         read-write shell on the volume, agent stopped
maria-logs           follow container logs
maria-doctor         the five setup failure modes, in order
maria-ledger [n]     recent decisions with principal / skill / perk / decision
```
