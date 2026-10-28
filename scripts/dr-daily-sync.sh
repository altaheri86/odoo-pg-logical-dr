#!/bin/bash
# Odoo DR - daily sync of application files from the production server. READ-ONLY on production.
#   1) rsync Odoo core, enterprise addons and filestore (rsync runs on prod at nice 19 / ionice idle)
#   2) custom modules: git fetch, then check out the commit production has deployed
#      (recorded on prod in $CUSTOM_DIR/.deployed-commit as "Commit= <sha>"); GIT_TARGET=main uses the branch tip
# Schedule : root crontab, every day 06:00 (cron does not catch up a missed run)
# Manual   : sudo dr-daily-sync.sh [--dry-run] [--skip-filestore]
# Config   : /etc/odoo-dr/dr.env (or $DR_ENV)
set -uo pipefail
source "${DR_ENV:-/etc/odoo-dr/dr.env}"
SSH="ssh -p $PROD_SSH_PORT -i $SSH_KEY -o BatchMode=yes -o UserKnownHostsFile=$KNOWN_HOSTS -o ServerAliveInterval=30 -o ServerAliveCountMax=6"
LOG=$LOG_DIR/dr-daily-sync.log
LOCK=/run/lock/odoo-dr-sync.lock

DRY=""; SKIP_FS=0
for a in "$@"; do
  case $a in
    --dry-run) DRY="--dry-run" ;;
    --skip-filestore) SKIP_FS=1 ;;
    *) echo "unknown option: $a"; exit 2 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)"; exit 2; }
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG") 2>&1
log() { echo "$(date '+%F %T') $*"; }
FAILED=()
exec 9>"$LOCK"
flock -n 9 || { log "another sync is already running - exit"; exit 1; }

log "===== daily sync start ${DRY:+(DRY RUN) }bw=${BW}KB/s git=$GIT_TARGET"
RSYNC=(rsync -rlpt $DRY --partial --delay-updates --compress --compress-choice=zstd --compress-level=3
       --bwlimit="$BW" --timeout=300 --rsync-path="nice -n 19 ionice -c3 rsync" -e "$SSH" --stats)

sync_dir() {  # name src dst owner [rsync opts...]
  local name=$1 src=$2 dst=$3 own=$4 out rc try; shift 4
  for try in 1 2 3; do
    log "-- $name: try $try"
    out=$("${RSYNC[@]}" --chown="$own" "$@" "$PROD_SSH:$src" "$dst" 2>&1); rc=$?
    echo "$out" | grep -e 'Number of regular files transferred' -e 'Number of deleted files' \
                       -e 'Total transferred file size' -e 'Total bytes received' | sed 's/^/   /'
    [ $rc -eq 0 ] && { log "-- $name: OK"; return 0; }
    echo "$out" | tail -n 5 | sed 's/^/   /'
    log "-- $name: rc=$rc"; [ $try -lt 3 ] && sleep 120
  done
  FAILED+=("$name"); return 1
}

# 1) core + enterprise: exact mirror. Local-only paths are excluded (and therefore never deleted).
sync_dir core "$ODOO_ROOT/" "$ODOO_ROOT/" "$ODOO_USER:$ODOO_GROUP" --delete \
  --exclude="/$(basename "$ENTERPRISE_DIR")/" --exclude="/$(basename "$CUSTOM_DIR")/" \
  --exclude=/venv/ --exclude=/.git/ --exclude=/.local/ --exclude=/.cache/ --exclude='/.dr-*' --exclude=__pycache__/
sync_dir enterprise "$ENTERPRISE_DIR/" "$ENTERPRISE_DIR/" "$ODOO_USER:$ODOO_GROUP" --delete --exclude=__pycache__/
# filestore: add/update only, never delete on DR (protects against an accidental delete on production)
if [ $SKIP_FS -eq 0 ]; then
  sync_dir filestore "$FILESTORE_DIR/" "$FILESTORE_DIR/" "$ODOO_USER:$ODOO_GROUP"
else
  log "-- filestore: skipped (--skip-filestore)"
fi

# 2) custom modules from git
git_sync() {
  export GIT_SSH_COMMAND="ssh -i $SSH_KEY -o BatchMode=yes -o UserKnownHostsFile=$KNOWN_HOSTS"
  local G="git -C $CUSTOM_DIR" target deployed head
  log "-- custom (git): fetch origin $GIT_BRANCH"
  $G fetch -q --depth 50 origin "$GIT_BRANCH" || { log "-- custom: git fetch failed"; return 1; }
  if [ "$GIT_TARGET" = main ]; then
    target=$($G rev-parse "origin/$GIT_BRANCH")
  else
    deployed=$($SSH -n "$PROD_SSH" "cat $CUSTOM_DIR/.deployed-commit" 2>/dev/null)
    target=$(echo "$deployed" | sed -n 's/^Commit= *//p' | tr -d '[:space:]')
    [[ $target =~ ^[0-9a-f]{40}$ ]] || { log "-- custom: cannot read .deployed-commit on production"; return 1; }
    $G cat-file -e "$target^{commit}" 2>/dev/null || $G fetch -q --deepen=500 origin "$GIT_BRANCH"
    $G cat-file -e "$target^{commit}" 2>/dev/null || { log "-- custom: $target not on $GIT_BRANCH"; return 1; }
    [ "$target" != "$($G rev-parse "origin/$GIT_BRANCH")" ] && \
      log "   note: $GIT_BRANCH is ahead of production ($($G rev-list --count "$target..origin/$GIT_BRANCH") commits not deployed yet)"
  fi
  head=$($G rev-parse HEAD)
  log "   DR: ${head:0:12}  ->  target: ${target:0:12}"
  if [ "$head" = "$target" ]; then log "-- custom: already up to date"; return 0; fi
  if [ -n "$DRY" ]; then $G diff --stat "$head" "$target" | tail -n 1 | sed 's/^/   /'; log "-- custom: dry run, not checked out"; return 0; fi
  $G reset -q --hard "$target" || return 1
  [ -n "${deployed:-}" ] && printf '%s\n' "$deployed" > "$CUSTOM_DIR/.deployed-commit"
  chown -R "$ODOO_USER:$ODOO_GROUP" "$CUSTOM_DIR"
  log "-- custom: OK now at ${target:0:12}"
}
git_sync || FAILED+=(custom-git)

if [ ${#FAILED[@]} -eq 0 ]; then
  log "===== daily sync OK"; exit 0
else
  log "===== daily sync FAILED: ${FAILED[*]}"; exit 1
fi
