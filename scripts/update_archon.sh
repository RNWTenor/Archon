#!/usr/bin/env bash
set -euo pipefail

# --- Config (override via env if you like) ------------------------------------
FORK_URL="${FORK_URL:-https://github.com/RNWTenor/Archon.git}"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/coleam00/Archon.git}"
FORK_REMOTE="${FORK_REMOTE:-origin}"
UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"

MAIN_BRANCH="${MAIN_BRANCH:-main}"       # keep pristine
WORK_BRANCH="${WORK_BRANCH:-myarchon}"   # your local working branch (containers run from here)

DOCKER_PROFILE="${DOCKER_PROFILE:-full}" # compose profile to bring up
UI_PORT="${UI_PORT:-3737}"               # host port used by archon-ui

MIRROR_UPSTREAM_BRANCHES="${MIRROR_UPSTREAM_BRANCHES:-0}"  # set 1 to mirror ALL branches to your fork
# ------------------------------------------------------------------------------

abort() { echo "❌ $*" >&2; exit 1; }
info()  { echo -e "\n👉 $*"; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || abort "Missing '$1' (install it first)"; }

# Sanity
[ -d .git ] || abort "Run this from the repo root ('.git' not found)."
require_cmd git
require_cmd docker

# 0) Ensure remotes
info "Ensuring remotes → ${FORK_REMOTE}=${FORK_URL}, ${UPSTREAM_REMOTE}=${UPSTREAM_URL}"
git remote | grep -qx "${FORK_REMOTE}"     || git remote add "${FORK_REMOTE}"     "${FORK_URL}"
git remote | grep -qx "${UPSTREAM_REMOTE}" || git remote add "${UPSTREAM_REMOTE}" "${UPSTREAM_URL}"
git remote set-url "${FORK_REMOTE}"     "${FORK_URL}"
git remote set-url "${UPSTREAM_REMOTE}" "${UPSTREAM_URL}"
git remote -v

# 1) Fetch everything
info "Fetching all refs (and pruning) …"
git fetch --all --prune
git fetch "${UPSTREAM_REMOTE}" --tags

# 2) Keep MAIN pristine: fast-forward from upstream, push to fork
info "Syncing ${MAIN_BRANCH} ← ${UPSTREAM_REMOTE}/${MAIN_BRANCH} (FF-only) …"

# Autosave WIP on current branch before switching (prevents checkout abort)
if ! git diff-index --quiet HEAD --; then
  info "Autosaving WIP on $(git rev-parse --abbrev-ref HEAD) before switching to ${MAIN_BRANCH} …"
  git add -A
  git commit -m "WIP: autosave before main sync ($(date -u +'%Y-%m-%dT%H:%M:%SZ'))"
fi

git switch "${MAIN_BRANCH}"
git merge --ff-only "${UPSTREAM_REMOTE}/${MAIN_BRANCH}" || abort "Non-FF merge needed on ${MAIN_BRANCH}. Resolve manually."
git push "${FORK_REMOTE}" "${MAIN_BRANCH}"

# (Optional) mirror ALL upstream branches to your fork
if [ "${MIRROR_UPSTREAM_BRANCHES}" = "1" ]; then
  info "Mirroring ALL upstream branches to ${FORK_REMOTE} …"
  while IFS= read -r b; do
    b="${b#${UPSTREAM_REMOTE}/}"
    [ -z "$b" ] && continue
    git switch -C "$b" "${UPSTREAM_REMOTE}/${b}"
    git push -u "${FORK_REMOTE}" "$b"
  done < <(git for-each-ref --format='%(refname:short)' "refs/remotes/${UPSTREAM_REMOTE}/")
  git switch "${MAIN_BRANCH}"
fi

# 3) Update WORK branch on top of MAIN (rebase preferred; fallback to merge)
if git show-ref --verify --quiet "refs/heads/${WORK_BRANCH}"; then
  info "Updating '${WORK_BRANCH}' on top of ${FORK_REMOTE}/${MAIN_BRANCH} …"
  git switch "${WORK_BRANCH}"
  if [ -n "$(git status --porcelain)" ]; then
    info "Autosaving local changes on ${WORK_BRANCH} …"
    git add -A
    git commit -m "WIP: autosave before sync ($(date -u +'%Y-%m-%dT%H:%M:%SZ'))"
  fi

  if git rebase "${FORK_REMOTE}/${MAIN_BRANCH}"; then
    git push --force-with-lease
  else
    info "Rebase conflict → aborting and merging instead …"
    git rebase --abort || true
    git merge --no-ff "${FORK_REMOTE}/${MAIN_BRANCH}"
    git push
  fi
else
  info "Creating '${WORK_BRANCH}' from ${MAIN_BRANCH} …"
  git switch "${MAIN_BRANCH}"
  git switch -c "${WORK_BRANCH}"
  git push -u "${FORK_REMOTE}" "${WORK_BRANCH}"
fi

# 4) Always run Docker from WORK branch (keep MAIN pure)
git switch "${WORK_BRANCH}"

# Free UI port if an old container is holding it
info "Checking for containers publishing port ${UI_PORT} …"
HOLDERS="$(docker ps --filter "publish=${UI_PORT}" --format '{{.ID}}\t{{.Names}}' || true)"
if [ -n "$HOLDERS" ]; then
  echo "$HOLDERS" | while read -r ID NAME; do
    info "Removing container holding :${UI_PORT}: $NAME"
    docker rm -f "$ID" >/dev/null 2>&1 || true
  done
fi

# Rebuild/restart the stack from WORK branch
info "Rebuilding Docker stack from '${WORK_BRANCH}' (profile=${DOCKER_PROFILE}) …"
docker compose down --remove-orphans || true
docker compose --profile "${DOCKER_PROFILE}" up -d --build --force-recreate --remove-orphans

info "✅ Done.
- ${MAIN_BRANCH} is pristine and synced with upstream
- '${WORK_BRANCH}' is updated on top of ${MAIN_BRANCH}
- Docker is running from '${WORK_BRANCH}'"

