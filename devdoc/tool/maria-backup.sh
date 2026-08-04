#!/usr/bin/env bash
# maria-backup.sh — snapshot the Maria agent state volume and push it to a
# configurable target (default: the homelab Mac over tailscale).
#
# Supersedes the node-local `maria-backup` bashrc function (devdoc/tool/maria.bashrc):
# same stop->snapshot->restart core, plus TARGET push + restore mode.
#
# The volume holds the agent's whole world: memories/, skills/, sessions/, cron/,
# platforms/, plans/, sandboxes/, workspace/, state.db, kanban.db, projects.db,
# config.yaml. ~14 MB -> ~5 MB tarball. Credentials (/run/maria tmpfs) are NOT in
# it, by design: restore gives state; the govd credential comes from the launch env.
#
#   # zero-stop snapshot (default): SQLite online-backup + live tar, no downtime
#   bash maria-backup.sh
#   # snapshot + push to the Mac over tailscale
#   BACKUP_TARGET=ruihe@100.101.222.80:~/maria-backups bash maria-backup.sh
#   # classic stop->tar->start (belt and braces, ~seconds of gateway blip)
#   STOP=1 bash maria-backup.sh
#   # restore (DESTRUCTIVE — replaces the whole volume)
#   bash maria-backup.sh --restore <archive.tar.gz>
#
# WHY NO STOP BY DEFAULT: the volume's three SQLite files (state.db, kanban.db,
# projects.db) have a live -wal, and a hot `tar` can capture a torn page. The
# zero-stop path snapshots each *.db through SQLite's own online-backup API
# (consistent, WAL included) and tars everything else live — plain files
# (memories/, skills/, sessions/, ...) are atomic-enough for hot copy. STOP=1
# keeps the old stop->tar->start for the paranoid.
#
# Env (all optional):
#   MARIA_VOL       state volume                          (default: maria_maria_state)
#   MARIA_CTR       agent container                       (default: maria)
#   BACKUP_DIR      local staging dir on this node        (default: ~/maria-backups)
#   BACKUP_KEEP     local archives to keep                (default: 10)
#   STOP            1 = stop the agent for the snapshot (default: 0 = zero-stop)
#   BACKUP_TARGET   rsync/scp destination; empty = local only
#   BACKUP_SSH_KEY  key for the target host               (default: ~/.ssh/id_ed25519)
#   PUSH_KEEP       remote archives to keep               (default: same as BACKUP_KEEP)

set -uo pipefail

MARIA_VOL="${MARIA_VOL:-maria_maria_state}"
MARIA_CTR="${MARIA_CTR:-maria}"
BACKUP_DIR="${BACKUP_DIR:-$HOME/maria-backups}"
BACKUP_KEEP="${BACKUP_KEEP:-10}"
STOP="${STOP:-0}"
BACKUP_TARGET="${BACKUP_TARGET:-}"
BACKUP_SSH_KEY="${BACKUP_SSH_KEY:-$HOME/.ssh/id_ed25519}"
PUSH_KEEP="${PUSH_KEEP:-$BACKUP_KEEP}"

say(){ printf '\n── %s\n' "$*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }

[ -n "$(command -v docker)" ] || die "docker not found — run on the node hosting $MARIA_VOL"
docker volume inspect "$MARIA_VOL" >/dev/null 2>&1 || die "no volume $MARIA_VOL (check MARIA_VOL / this is the maria node)"

snapshot() {
  mkdir -p "$BACKUP_DIR"
  local stamp out was_up=0
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  out="$BACKUP_DIR/maria-state-$stamp.tar.gz"

  if [ "$STOP" = "1" ] && docker ps --format '{{.Names}}' | grep -qx "$MARIA_CTR"; then
    was_up=1
    say "stopping $MARIA_CTR for a consistent snapshot (STOP=1)"
    docker stop "$MARIA_CTR" >/dev/null
  fi

  # Zero-stop path: SQLite online-backup each *.db (consistent, WAL included),
  # then tar everything else live. Both steps inside one throwaway container so
  # the archive is written in one pass; python:3-alpine has sqlite3 built in.
  say "snapshotting $MARIA_VOL -> $out"
  docker run --rm -v "$MARIA_VOL":/src:ro -v "$BACKUP_DIR":/dst python:3-alpine \
    python3 - "$(basename "$out")" <<'PY'
import glob, os, sqlite3, sys, tarfile

out = f"/dst/{sys.argv[1]}"
src = "/src"

# 1. consistent copies of every SQLite database via the online backup API
os.makedirs("/dst/.dbs", exist_ok=True)
for db in glob.glob(f"{src}/*.db"):
    name = os.path.basename(db)
    s = sqlite3.connect(db)
    d = sqlite3.connect(f"/dst/.dbs/{name}")
    s.backup(d)
    d.close(); s.close()
    print(f"   sqlite backup: {name}")

# 2. tar the rest live, excluding the SQLite family (their consistent copies
#    live under .dbs/ inside the same archive)
def keep(ti):
    base = os.path.basename(ti.name)
    if base.endswith((".db", ".db-wal", ".db-shm")):
        return None
    return ti

with tarfile.open(out, "w:gz") as tf:
    tf.add(src, arcname=".", filter=keep)
    tf.add("/dst/.dbs", arcname=".dbs")
print("   archive written")
PY
  local rc=$?
  rm -rf "$BACKUP_DIR/.dbs"

  [ "$was_up" = 1 ] && { say "restarting $MARIA_CTR"; docker start "$MARIA_CTR" >/dev/null; }
  [ $rc -eq 0 ] || die "snapshot failed (rc=$rc)"
  say "snapshot: $out ($(du -h "$out" | cut -f1))"

  # prune local beyond BACKUP_KEEP
  ls -1t "$BACKUP_DIR"/maria-state-*.tar.gz 2>/dev/null | tail -n +$((BACKUP_KEEP+1)) \
    | while read -r f; do rm -f "$f" && echo "   pruned local $(basename "$f")"; done
  echo "$out"
}

push() {
  [ -n "$BACKUP_TARGET" ] || { echo "   (no BACKUP_TARGET — local only)"; return 0; }
  local out="$1"
  local host_path="${BACKUP_TARGET%%:*}" remote_dir="${BACKUP_TARGET#*:}"
  local rsync_opts=(-az --partial --mkpath)
  [ -n "$BACKUP_SSH_KEY" ] && [ -f "$BACKUP_SSH_KEY" ] && rsync_opts+=(-e "ssh -i $BACKUP_SSH_KEY -o BatchMode=yes")

  say "pushing to $BACKUP_TARGET (tailnet)"
  if command -v rsync >/dev/null 2>&1; then
    rsync "${rsync_opts[@]}" "$out" "$BACKUP_TARGET" || die "rsync push failed"
    # remote pruning: keep the newest PUSH_KEEP on the far side
    if [ -n "$PUSH_KEEP" ]; then
      ssh -i "$BACKUP_SSH_KEY" -o BatchMode=yes "$host_path" \
        "ls -1t $remote_dir/maria-state-*.tar.gz 2>/dev/null | tail -n +$((PUSH_KEEP+1)) | xargs -r rm -f" \
        >/dev/null 2>&1 && echo "   pruned remote beyond $PUSH_KEEP" || true
    fi
  else
    # scp fallback (no --mkpath; assume remote dir exists)
    scp -i "$BACKUP_SSH_KEY" -o BatchMode=yes "$out" "$BACKUP_TARGET" || die "scp push failed"
  fi
  echo "   pushed $(basename "$out")"
}

list_backups() {
  say "local archives ($BACKUP_DIR)"
  ls -lht "$BACKUP_DIR"/maria-state-*.tar.gz 2>/dev/null | awk '{print "  "$5, $6, $7, $8, $9}' || echo "  none"
}

restore() {
  local f="${1:-}"
  [ -f "$f" ] || die "usage: maria-backup.sh --restore <archive.tar.gz>"
  echo "!! DESTRUCTIVE: replaces EVERYTHING in $MARIA_VOL (memories, skills, sessions, auth)"
  echo "   archive: $f"
  printf "   type RESTORE to proceed: "; local a; read -r a
  [ "$a" = "RESTORE" ] || die "aborted"

  docker ps --format '{{.Names}}' | grep -qx "$MARIA_CTR" && { say "stopping $MARIA_CTR"; docker stop "$MARIA_CTR" >/dev/null; }
  # extract, then hoist the .dbs/ consistent copies back to the volume root
  docker run --rm -v "$MARIA_VOL":/dst -v "$(dirname "$(realpath "$f")")":/src:ro alpine \
    sh -c 'rm -rf /dst/* /dst/.[!.]* 2>/dev/null; tar xzf "/src/$(basename "'"$f"'")" -C /dst && [ -d /dst/.dbs ] && mv -f /dst/.dbs/*.db /dst/ && rm -rf /dst/.dbs' \
    || die "restore failed"
  say "restored — starting $MARIA_CTR"
  docker start "$MARIA_CTR" >/dev/null
  echo "   credential note: /run/maria tmpfs was re-created empty — the govd token"
  echo "   must come from the launch env (MARIA_GOVD_TOKEN), exactly as on first boot."
}

case "${1:-}" in
  --restore) restore "${2:-}" ;;
  --list|-l) list_backups ;;
  *)         out="$(snapshot)"; push "$out"; list_backups ;;
esac
