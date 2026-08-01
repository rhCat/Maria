# Branching — why `dev` is the trunk and `main` is not

This repo is a **fork of `NousResearch/hermes-agent`**, and that decides the whole layout.

```
origin    github.com/rhCat/Maria.git
upstream  github.com/NousResearch/hermes-agent.git
```

## `main` is an upstream mirror, not a release branch

`origin/main` carries upstream's history — its head is a NousResearch merge commit, and the fork holds all
of upstream's branches. As of 2026-07-26 **upstream is 1320 commits ahead of it**.

So `main` has exactly one job: be a clean point to sync upstream into. **Never commit Maria work there.**
Cherry-picking cyberware integration into `main` would poison the only clean merge base against a
1320-commit gap, and buy nothing — none of this work is upstreamable. `agent/govern_gate.py`, its tests and
`docker-compose.maria.yml` do not exist upstream; they are cyberware integration NousResearch has no reason
to take.

## `dev` is the trunk

`dev` carries every Maria-specific change and is what gets deployed. Work branches off it and returns by PR:

```
feature branch  ──PR──▶  dev  ──tag──▶  release (maria-vX.Y.Z)
                          ▲
              upstream ──▶ main ──merge──▶ dev      (sync, when you want upstream's changes)
```

- **Feature work** — branch from `dev`, PR into `dev`. Same review gate as before.
- **Releases** — tag on `dev`. Do **not** merge into `main`; a tag is the release marker, and `main` stays a
  mirror.
- **Upstream sync** — `git fetch upstream && git checkout main && git merge --ff-only upstream/main`, then
  merge `main` into `dev` and resolve. Never the other direction.

## The sync surface — keep it small

Most Maria work lives in files upstream has never seen, which conflict with nothing. The risk is confined to
the handful of **upstream-owned** files we hook into:

| file | our delta |
|---|---|
| `agent/tool_executor.py` | +75 / −0 |
| `cli-config.yaml.example` | +25 / −0 |
| `model_tools.py` | +24 / −0 |
| `tools/approval.py` | +24 / −0 |

**148 added lines, zero deletions.** That is the property to preserve: our edits are additive hooks — the
gate call sites at the executor waist and the `handle_function_call` re-entry — not rewrites. Keep it that
way and an upstream merge stays mechanical. Start restructuring upstream code and every future sync becomes
a negotiation.

If a change *can* live in a Maria-only module, put it there. Editing `approval.py` should feel like a cost.

## Not yet done

- **`dev` is not the default branch on GitHub.** Worth switching, so PRs and clones land on the trunk rather
  than the upstream mirror. Repo setting, not a commit.
- **`docker-compose.maria.yml`, `Dockerfile.maria`, `docker/litellm/` and `scripts/verify-maria-cage.sh` are
  untracked.** The deployment config is not under version control at all — it should be, on `dev`.
- **The fork has never been synced** (1320 behind). Not urgent, but the longer it waits the larger the merge.
