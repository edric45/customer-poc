#!/usr/bin/env bash
# Copy public images into the regional Harbor: pull, retag, push, clean up.
#
#   export HARBOR=harbor.customer.local HARBOR_PROJECT=library HARBOR_USER=admin
#   ./scripts/mirror-images.sh                       # images from scripts/images.txt
#   ./scripts/mirror-images.sh my-images.txt         # or another list
#   DRY_RUN=1 ./scripts/mirror-images.sh             # print what would happen
#
# Environment:
#   HARBOR            Harbor hostname                        (required)
#   HARBOR_PROJECT    Harbor project to push into            (default: library)
#   HARBOR_USER       Harbor user or robot account           (required)
#   HARBOR_PASSWORD   its password; prompted for when unset  (never put it in a file in git)
#   IMAGES_FILE       image list                             (default: scripts/images.txt; first argument wins)
#   PLATFORM          image platform to pull                 (default: linux/amd64, the VKS nodes)
#   CREATE_PROJECT    1 = create HARBOR_PROJECT if missing   (default: 0)
#   PROJECT_PUBLIC    1 = a created project is public        (default: 1, pulls need no secret)
#   CLEANUP           1 = remove local copies after each push (default: 1)
#   DRY_RUN           1 = print the commands, run nothing    (default: 0)
#
# Needs: docker (with the daemon proxy set, docs/jumphost.md section 6) and
# Harbor's CA trusted by Docker (docs/harbor-trust.md section 3). curl only
# for CREATE_PROJECT.
#
# Prints, per image, source -> target, and a summary; exits 1 if any failed.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
IMAGES_FILE=${1:-${IMAGES_FILE:-$HERE/images.txt}}
HARBOR=${HARBOR:-}
HARBOR_PROJECT=${HARBOR_PROJECT:-library}
HARBOR_USER=${HARBOR_USER:-}
PLATFORM=${PLATFORM:-linux/amd64}
CREATE_PROJECT=${CREATE_PROJECT:-0}
PROJECT_PUBLIC=${PROJECT_PUBLIC:-1}
CLEANUP=${CLEANUP:-1}
DRY_RUN=${DRY_RUN:-0}

die() { echo "error: $*" >&2; exit 2; }
run() {
  if [ "$DRY_RUN" = 1 ]; then echo "  + $*"; else "$@"; fi
}

[ -n "$HARBOR" ] || die "set HARBOR (e.g. export HARBOR=harbor.customer.local)"
[ -n "$HARBOR_USER" ] || die "set HARBOR_USER (a Harbor user or robot account)"
[ -f "$IMAGES_FILE" ] || die "image list not found: $IMAGES_FILE"
if [ "$DRY_RUN" != 1 ]; then
  command -v docker >/dev/null || die "docker not found"
fi

# Turn a reference into the path inside Harbor: drop the registry, keep the
# repository path and the tag (or digest).
#   busybox:1.37                   -> busybox:1.37
#   grafana/grafana:13.2.4         -> grafana/grafana:13.2.4
#   quay.io/kiwigrid/k8s-sidecar:2 -> kiwigrid/k8s-sidecar:2
#   repo@sha256:abc...             -> repo:sha256-abc... (a pushed image needs a tag)
target_path() {
  local ref=$1 name rest first
  name=${ref%%@*}
  first=${name%%/*}
  # a first part with a dot or colon, or "localhost", is a registry
  if [ "$first" != "$name" ] && { case $first in *.*|*:*|localhost) true;; *) false;; esac; }; then
    rest=${name#*/}
    case $first in docker.io|index.docker.io|registry-1.docker.io) rest=${rest#library/};; esac
  else
    rest=${name#library/}        # docker.io/library/x and x are the same image
  fi
  if [ "$ref" != "${ref%%@*}" ]; then
    local digest=${ref#*@}
    rest="${rest%%:*}:${digest/:/-}"
  else
    # strip a tag only after the last slash, so registry ports survive
    case ${rest##*/} in *:*) ;; *) rest="$rest:latest";; esac
  fi
  echo "$rest"
}

# Read the list (portable: no mapfile, works with macOS bash 3.2 too).
IMAGES=()
while IFS= read -r line || [ -n "$line" ]; do
  line=${line%%#*}
  line=$(echo "$line" | tr -d '[:space:]')
  [ -n "$line" ] && IMAGES+=("$line")
done < "$IMAGES_FILE"
[ ${#IMAGES[@]} -gt 0 ] || die "no images in $IMAGES_FILE"

echo "Harbor:   $HARBOR/$HARBOR_PROJECT"
echo "Images:   ${#IMAGES[@]} from $IMAGES_FILE"
echo "Platform: $PLATFORM   cleanup: $CLEANUP   dry run: $DRY_RUN"

# Login (password from the environment, or asked for; never on the command line).
if [ "$DRY_RUN" = 1 ]; then
  echo "  + docker login $HARBOR -u $HARBOR_USER --password-stdin"
else
  if [ -z "${HARBOR_PASSWORD:-}" ]; then
    read -r -s -p "Password for $HARBOR_USER@$HARBOR: " HARBOR_PASSWORD; echo
  fi
  printf '%s' "$HARBOR_PASSWORD" | docker login "$HARBOR" -u "$HARBOR_USER" --password-stdin >/dev/null
  echo "Logged in to $HARBOR"
fi

if [ "$CREATE_PROJECT" = 1 ]; then
  public=$([ "$PROJECT_PUBLIC" = 1 ] && echo true || echo false)
  if [ "$DRY_RUN" = 1 ]; then
    echo "  + create project $HARBOR_PROJECT (public=$public) if missing"
  else
    code=$(curl -s -o /dev/null -w '%{http_code}' --noproxy "$HARBOR" \
      -u "$HARBOR_USER:$HARBOR_PASSWORD" "https://$HARBOR/api/v2.0/projects?project_name=$HARBOR_PROJECT" -I)
    if [ "$code" = 404 ]; then
      curl -sf --noproxy "$HARBOR" -u "$HARBOR_USER:$HARBOR_PASSWORD" -H 'Content-Type: application/json' \
        -d "{\"project_name\":\"$HARBOR_PROJECT\",\"metadata\":{\"public\":\"$public\"}}" \
        "https://$HARBOR/api/v2.0/projects" && echo "Created project $HARBOR_PROJECT"
    else
      echo "Project $HARBOR_PROJECT exists (HTTP $code)"
    fi
  fi
fi

ok=0; failed=()
for src in "${IMAGES[@]}"; do
  dst="$HARBOR/$HARBOR_PROJECT/$(target_path "$src")"
  echo
  echo "== $src"
  echo "   -> $dst"
  if run docker pull --platform "$PLATFORM" "$src" \
     && run docker tag "$src" "$dst" \
     && run docker push "$dst"; then
    ok=$((ok + 1))
  else
    failed+=("$src")
  fi
  if [ "$CLEANUP" = 1 ]; then
    if [ "$DRY_RUN" = 1 ]; then
      echo "  + docker image rm $dst $src"
    else
      docker image rm "$dst" "$src" >/dev/null 2>&1 || true
    fi
  fi
done

if [ "$CLEANUP" = 1 ] && [ "$DRY_RUN" != 1 ]; then
  docker image prune -f >/dev/null || true      # dangling layers left by the removals
fi

echo
echo "Done: $ok of ${#IMAGES[@]} pushed to $HARBOR/$HARBOR_PROJECT$([ "$DRY_RUN" = 1 ] && echo " (dry run: nothing was pushed)")"
if [ ${#failed[@]} -gt 0 ]; then
  echo "Failed:"; printf '  %s\n' "${failed[@]}"
  exit 1
fi
