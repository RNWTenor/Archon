#!/usr/bin/env bash
set -euo pipefail

# --- Config (you can override via env vars) -----------------------------------
FORK_URL="${FORK_URL:-https://github.com/RNWTenor/Archon.git}"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/coleam00/Archon.git}"
FORK_REMOTE="${FORK_REMOTE:-origin}"
UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"

MAIN_BRANCH="${MAIN_BRANCH:-main}"
WORK_BRANCH="${WORK_BRANCH:-myarchon}"

DOCKER_PROFILE="${DOCKER_PROFILE:-full}"     # profile to use for compose
UI_PORT="${UI_PORT:-3737}"                   # host port used by archon-ui

MIRROR_UPSTREAM_BRANCHES="${MIRROR_UPSTREAM_BRANCHES:-0}"  # 1 to push ALL upstream branches to your fork
# ------------------------------------------------------------------------------

# Helpers
abort() { echo "❌ $*" >&2; exit 1; }
info()  { echo -e "\n👉 $*"; }

# 0) Sanity checks
[ -d .git ] || abort "Run this from the repo root (no .git found)."

# 1) Ensure remotes are correct
info "Ensuring remotes → ${FORK_REMOTE}=${FORK_URL}, ${UPSTREAM_REMOTE}=${UPSTREAM_URL}"
git remote | grep -qx "${FORK_REMOTE}"     || git remote add "${FORK_REMOTE}"     "${FORK_URL}"
git remote | grep -qx "${UPSTREAM_REMOTE}" || git remote add "${UPSTREAM_REMOTE}" "${UPSTREAM_URL}"

git remote set-url "${FORK_REMOTE}"     "${FORK_URL}"
git remote set-url "${UPSTREAM_REMOTE}" "${UPSTREAM_URL}"

git remote -v

# Save current branch to restore later
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD || echo "${MAIN_BRANCH}")"

# 2) Fetch everything
info "Fetching all refs (and pruning stale ones)…"
git fetch --all --prune
git fetch "${UPSTREAM_REMOTE}" --tags

# 3) Fast-forward local main from upstream, then push to fork
info "Syncing ${MAIN_BRANCH} ← ${UPSTREAM_REMOTE}/${MAIN_BRANCH} (fast-forward only)…"
git switch "${MAIN_BRANCH}"
git merge --ff-only "${UPSTREAM_REMOTE}/${MAIN_BRANCH}" || abort "Non-FF merge needed on ${MAIN_BRANCH}. Resolve manually."
git push "${FORK_REMOTE}" "${MAIN_BRANCH}"

# 4) (Optional) Mirror ALL upstream branches into your fork
if [ "${MIRROR_UPSTREAM_BRANCHES}" = "1" ]; then
  info "Mirroring ALL upstream branches to your fork (${FORK_REMOTE})…"
  while IFS= read -r b; do
    b="${b#${UPSTREAM_REMOTE}/}"
    [ -z "$b" ] && continue
    git switch -C "$b" "${UPSTREAM_REMOTE}/${b}"
    git push -u "${FORK_REMOTE}" "$b"
  done < <(git for-each-ref --format='%(refname:short)' "refs/remotes/${UPSTREAM_REMOTE}/")
  # Return to main for Docker step later
  git switch "${MAIN_BRANCH}"
fi

# 5) Ensure work branch exists, autosave local changes, rebase (or merge) on main
if git show-ref --verify --quiet "refs/heads/${WORK_BRANCH}"; then
  info "Updating your work branch '${WORK_BRANCH}'…"
  git switch "${WORK_BRANCH}"

  if [ -n "$(git status --porcelain)" ]; then
    info "Autosaving local changes on ${WORK_BRANCH}…"
    git add -A
    git commit -m "WIP: autosave before sync ($(date -u +'%Y-%m-%dT%H:%M:%SZ'))"
  fi

  info "Rebasing ${WORK_BRANCH} on ${FORK_REMOTE}/${MAIN_BRANCH}…"
  if git rebase "${FORK_REMOTE}/${MAIN_BRANCH}"; then
    git push --force-with-lease
  else
    info "Rebase failed; aborting rebase and doing a no-ff merge instead…"
    git rebase --abort || true
    git merge --no-ff "${FORK_REMOTE}/${MAIN_BRANCH}"
    git push
  fi
else
  info "Creating your work branch '${WORK_BRANCH}' from ${MAIN_BRANCH}…"
  git switch "${MAIN_BRANCH}"
  git switch -c "${WORK_BRANCH}"
  git push -u "${FORK_REMOTE}" "${WORK_BRANCH}"
fi

# 6) Switch back to main for runtime and update Docker
git switch "${MAIN_BRANCH}"

# 6a) Free up UI port if an old/orphan container is holding it
info "Checking for containers publishing port ${UI_PORT}…"
HOLDERS="$(docker ps --filter "publish=${UI_PORT}" --format '{{.ID}}\t{{.Names}}' || true)"
if [ -n "$HOLDERS" ]; then
  echo "$HOLDERS" | while read -r ID NAME; do
    info "Stopping & removing container holding :${UI_PORT}: $NAME"
    docker rm -f "$ID" >/dev/null 2>&1 || true
  done
fi

# 6b) Rebuild/refresh the stack on main
info "Refreshing Docker stack on ${MAIN_BRANCH} (profile=${DOCKER_PROFILE})…"
docker compose down --remove-orphans || true
docker compose --profile "${DOCKER_PROFILE}" up -d --build --force-recreate --remove-orphans

info "✅ Done.
- Fork main is synced with upstream
- '${WORK_BRANCH}' is updated on top of main
- Docker stack rebuilt on '${MAIN_BRANCH}'
(Current branch: $(git rev-parse --abbrev-ref HEAD))"

