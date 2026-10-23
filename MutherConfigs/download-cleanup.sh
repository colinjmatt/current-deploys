#!/usr/bin/env bash
set -euo pipefail

# ===== Config =====
transmissionuser='transmission'
transmissionpass='1234abcd'

downloads='/downloads'
incomplete='/downloads/incomplete'

# Delete torrents this long after completion (21 days)
age_seconds=$((86400*21))

# Set to 1 to preview actions only
DRY_RUN=0

transmissionr() {
  transmission-remote -n "${transmissionuser}:${transmissionpass}" "$@"
}

rm_safe() {
  if (( DRY_RUN )); then
    printf '[DRY RUN] rm -rf -- %q\n' "$@"
  else
    rm -rf -- "$@"
  fi
}

remove_and_delete() {
  local id="$1"
  if (( DRY_RUN )); then
    echo "[DRY RUN] Would remove+delete torrent id ${id}"
  else
    transmissionr -t "$id" --remove-and-delete
  fi
}

# ===== Safety: ensure transmission-daemon is running =====
if ! pgrep -f '/usr/bin/transmission-daemon' >/dev/null 2>&1; then
  echo "transmission-daemon not running; refusing to run."
  exit 1
fi

now_epoch="$(date +%s)"

# ===== Get torrent IDs =====
mapfile -t torrent_ids < <(
  transmissionr -l |
    sed '1d;$d' |
    awk '{print $1}' |
    sed 's/[^0-9]//g' |
    sed '/^$/d'
)

if (( DRY_RUN )); then
  echo "[DRY RUN] Found ${#torrent_ids[@]} torrent(s) total."
fi

# ===== Helper: get Date finished as epoch (0 if not finished / unparseable) =====
get_finished_epoch() {
  local id="$1"
  local finished_str finished_epoch

  finished_str="$(
    transmissionr -t "$id" -i 2>/dev/null |
      sed -nE 's/^ *Date finished:[[:space:]]+//p' |
      head -n 1 |
      tr -d '\r' || true
  )"

  [[ -z "$finished_str" ]] && { echo 0; return 0; }

  finished_epoch="$(date -d "$finished_str" +%s 2>/dev/null || true)"
  [[ -z "$finished_epoch" ]] && finished_epoch=0

  echo "$finished_epoch"
}

# ===== 1) Remove torrents older than age_seconds since completion =====
eligible_count=0

for id in "${torrent_ids[@]}"; do
  finished_epoch="$(get_finished_epoch "$id")"

  # Not finished => skip
  if (( finished_epoch <= 0 )); then
    continue
  fi

  finished_age=$(( now_epoch - finished_epoch ))

  if (( finished_age > age_seconds )); then
    ((eligible_count++))
    if (( DRY_RUN )); then
      echo "[DRY RUN] Torrent id ${id} finished ${finished_age}s ago (> ${age_seconds}s) -> eligible"
    fi
    remove_and_delete "$id"
  fi
done

if (( DRY_RUN )); then
  echo "[DRY RUN] Eligible by 'finished age' rule: ${eligible_count}"
fi

# ===== 2) Delete orphaned items on disk that Transmission no longer knows about =====
declare -A known_names=()

for id in "${torrent_ids[@]}"; do
  info="$(transmissionr -t "$id" -i 2>/dev/null || true)"
  [[ -z "$info" ]] && continue

  name="$(awk -F': *' '/^ *Name:/ {print $2; exit}' <<<"$info" || true)"
  [[ -n "$name" ]] && known_names["$name"]=1
done

list_children() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  find "$dir" -mindepth 1 -maxdepth 1 -print0
}

declare -a delete_paths=()

while IFS= read -r -d '' path; do
  base="$(basename "$path")"

  # Hard exclusions – NEVER delete these
  case "$path" in
    "$incomplete"|"${incomplete}/"*) continue ;;
  esac

  # Skip known structural directories
  case "$base" in
    "complete"|"films-radarr"|"tv-sonarr") continue ;;
  esac

  # Only delete if Transmission does not know about it
  if [[ -z "${known_names[$base]+x}" ]]; then
    delete_paths+=("$path")
  fi
done < <(list_children "$downloads")

if ((${#delete_paths[@]})); then
  echo "Orphaned items to delete under ${downloads}:"
  printf '  %q\n' "${delete_paths[@]}"
  rm_safe "${delete_paths[@]}"
else
  echo "No orphaned items found under ${downloads}."
fi