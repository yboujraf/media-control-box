#!/usr/bin/env bash
# docker.sh — run/update containers predictably with spec hash
set -euo pipefail
# requires: core.sh

docker_pull_if_needed() {
  local image="${1:?}"
  if is_dry_run; then info "DRY-RUN docker pull $image"; return 0; fi
  docker pull "$image" >/dev/null || true
}

# docker_run_or_replace <service> <name> <image> <spec_hash> -- <docker-run opts...> -- <container cmd...>
docker_run_or_replace() {
  local svc="${1:?}"; local name="${2:?}"; local image="${3:?}"; local spec_hash="${4:?}"; shift 4
  [[ "$1" == "--" ]] && shift || true

  # Split docker run options vs container command at the first "--"
  local docker_opts=()
  local container_cmd=()
  local saw_sep=0
  while (( "$#" )); do
    if [[ "$1" == "--" && $saw_sep -eq 0 ]]; then
      saw_sep=1; shift; continue
    fi
    if [[ $saw_sep -eq 0 ]]; then docker_opts+=("$1"); else container_cmd+=("$1"); fi
    shift
  done

  local sd; sd="$(state_dir "$svc")"
  local hf="$sd/${name}.sha256"
  local prev="$(cat "$hf" 2>/dev/null || true)"

  docker_pull_if_needed "$image"

  if docker inspect "$name" >/dev/null 2>&1; then
    if [[ "$prev" == "$spec_hash" ]]; then
      info "container $name unchanged (spec match)"
      docker start "$name" >/dev/null || true
      return 0
    fi
    info "container $name spec changed; will recreate"
    if ! is_dry_run; then docker rm -f "$name" >/dev/null 2>&1 || true; fi
  fi

  if is_dry_run; then
    info "DRY-RUN docker run $name ($image) with new spec"
    return 0
  fi

  if (( ${#container_cmd[@]} )); then
    docker run -d --name "$name" --restart unless-stopped "${docker_opts[@]}" "$image" "${container_cmd[@]}"
  else
    docker run -d --name "$name" --restart unless-stopped "${docker_opts[@]}" "$image"
  fi
  printf "%s\n" "$spec_hash" > "$hf"
  echo "updated:container:$name"
}

docker_is_healthy() {
  local name="${1:?}"
  [[ "$(docker inspect -f '{{.State.Health.Status}}' "$name" 2>/dev/null || echo "unknown")" == "healthy" ]]
}

docker_logs_tail() {
  local name="${1:?}"; local n="${2:-100}"
  docker logs --tail "$n" "$name" 2>&1 || true
}
