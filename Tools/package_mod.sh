#!/usr/bin/env bash
set -euo pipefail

# Package a Factorio mod from mods/<dir>/ into <name>_<version>.zip
# and copy it to ansible/files/mods (local) and/or deploy to a remote server.
#
# Requirements: bash, zip, jq, rsync (optional), scp/ssh for remote deploy.
#
# Usage examples:
#   Tools/package_mod.sh                                  # build and copy to ansible/files/mods
#   Tools/package_mod.sh --source mods/agent_0.0.1        # explicit source dir
#   Tools/package_mod.sh --remote trip@host               # also deploy to remote:/srv/factorio/mods
#   Tools/package_mod.sh --remote auto                    # infer remote from ansible/inventory.yml
#   Tools/package_mod.sh --data-dir /srv/factorio         # change remote data_dir
#   Tools/package_mod.sh --owner factorio:factorio        # chown on remote after copy
#   Tools/package_mod.sh --dry-run                        # print what would happen

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DEFAULT_OUTPUT_DIR="$ROOT_DIR/ansible/files/mods"
DEFAULT_LOCAL_MODS_DIR="$ROOT_DIR/mods"
STAGING_DIR="$ROOT_DIR/.dist/mod_build"
mkdir -p "$STAGING_DIR"

OUTPUT_DIR="$DEFAULT_OUTPUT_DIR"
SOURCE_DIR=""
REMOTE=""
REMOTE_DATA_DIR="/srv/factorio"
REMOTE_OWNER=""
DRY_RUN=false
# restart controls (when deploying to remote)
RESTART=true
INSTANCES=""           # comma-separated names, e.g., ai1,ai2
SYSTEMD_PREFIX="factorio"

print_help() {
  cat <<EOF
Package and optionally deploy a Factorio mod zip.

Options:
  -s, --source <dir>       Source mod directory (default: auto-detect under mods/)
  -o, --output-dir <dir>   Local output directory (default: $DEFAULT_OUTPUT_DIR)
      --remote <user@host|auto>
                           Deploy to remote (scp to <remote>:$REMOTE_DATA_DIR/mods)
      --data-dir <dir>     Remote data_dir (default: $REMOTE_DATA_DIR)
      --owner <user:group> chown on remote after copy (default: none)
  --instances <n1,n2>  Instance names to restart (default: auto-detect factorio-*.service)
  --no-restart         Do not restart services on remote (default: restart)
  --restart            Explicitly enable restart (default when --remote is used)
      --dry-run            Print actions without executing
  -h, --help               This help
EOF
}

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--source) SOURCE_DIR="$2"; shift 2 ;;
    -o|--output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    --remote) REMOTE="$2"; shift 2 ;;
    --data-dir) REMOTE_DATA_DIR="$2"; shift 2 ;;
    --owner) REMOTE_OWNER="$2"; shift 2 ;;
  --instances) INSTANCES="$2"; shift 2 ;;
  --no-restart) RESTART=false; shift ;;
  --restart) RESTART=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) print_help; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; print_help; exit 2 ;;
  esac
done

# Auto-detect remote from ansible/inventory.yml when --remote auto
if [[ "$REMOTE" == "auto" ]]; then
  INV="$ROOT_DIR/ansible/inventory.yml"
  if [[ -f "$INV" ]]; then
    host=$(awk '/hosts:/{f=1;next} f && /^[[:space:]]+[A-Za-z0-9_.-]+:/{gsub(":","",$1); print $1; exit}' "$INV")
    user=$(awk '/ansible_user:/{print $2; exit}' "$INV")
    if [[ -n "${host:-}" && -n "${user:-}" ]]; then
      REMOTE="$user@$host"
    else
      echo "Could not infer remote from $INV; please pass --remote user@host" >&2
      exit 1
    fi
  else
    echo "No ansible/inventory.yml; please pass --remote user@host" >&2
    exit 1
  fi
fi

need jq
need zip
# rsync is optional; fallback to cp
if ! command -v rsync >/dev/null 2>&1; then
  RSYNC=""
else
  RSYNC="rsync"
fi

# Resolve source dir
if [[ -z "$SOURCE_DIR" ]]; then
  # pick the newest dir in mods/* containing info.json
  mapfile -t candidates < <(find "$DEFAULT_LOCAL_MODS_DIR" -mindepth 1 -maxdepth 1 -type d -print0 | xargs -0 -I{} bash -c 'test -f "{}/info.json" && echo "{}"' | xargs -I{} bash -c 'stat -c "%Y:%n" "{}"' | sort -nr | cut -d: -f2-)
  if [[ ${#candidates[@]} -eq 0 ]]; then
    echo "No mod source found under $DEFAULT_LOCAL_MODS_DIR (expecting a folder with info.json)" >&2
    exit 1
  fi
  SOURCE_DIR="${candidates[0]}"
fi

if [[ ! -f "$SOURCE_DIR/info.json" ]]; then
  echo "info.json not found in $SOURCE_DIR" >&2
  exit 1
fi

NAME=$(jq -r '.name' "$SOURCE_DIR/info.json")
VERSION=$(jq -r '.version' "$SOURCE_DIR/info.json")
if [[ -z "$NAME" || -z "$VERSION" || "$NAME" == "null" || "$VERSION" == "null" ]]; then
  echo "Failed to read name/version from $SOURCE_DIR/info.json" >&2
  exit 1
fi
OUT_BASENAME="${NAME}_${VERSION}"
ZIP_NAME="${OUT_BASENAME}.zip"

# Build staging
PKG_PARENT="$STAGING_DIR"
PKG_DIR="$PKG_PARENT/$OUT_BASENAME"
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR"

# Copy files
if [[ -n "$RSYNC" ]]; then
  $DRY_RUN && echo rsync -a --delete --exclude ".git" --exclude "*.zip" --exclude "dist" "$SOURCE_DIR/" "$PKG_DIR/" || \
  rsync -a --delete --exclude ".git" --exclude "*.zip" --exclude "dist" "$SOURCE_DIR/" "$PKG_DIR/"
else
  $DRY_RUN && echo cp -a "$SOURCE_DIR/." "$PKG_DIR/" || cp -a "$SOURCE_DIR/." "$PKG_DIR/"
  # prune obvious ignores
  rm -rf "$PKG_DIR/.git" "$PKG_DIR"/*.zip "$PKG_DIR/dist" 2>/dev/null || true
fi

# Create zip so that top-level inside the zip is <name>_<version>/
mkdir -p "$OUTPUT_DIR"
ZIP_TMP="$PKG_PARENT/$ZIP_NAME"
(
  cd "$PKG_PARENT"
  $DRY_RUN && echo zip -r "${ZIP_TMP}" "${OUT_BASENAME}" || zip -r "${ZIP_TMP}" "${OUT_BASENAME}" >/dev/null
)

# Copy to local ansible/files/mods
DEST_LOCAL="$OUTPUT_DIR/$ZIP_NAME"
$DRY_RUN && echo cp -f "$ZIP_TMP" "$DEST_LOCAL" || cp -f "$ZIP_TMP" "$DEST_LOCAL"

echo "Packaged: $DEST_LOCAL"

# Optional remote deploy
if [[ -n "$REMOTE" ]]; then
  need scp; need ssh
  REMOTE_MODS_DIR="$REMOTE_DATA_DIR/mods"
  if $DRY_RUN; then
    echo ssh "$REMOTE" mkdir -p "$REMOTE_MODS_DIR"
    echo scp "$ZIP_TMP" "$REMOTE:$REMOTE_MODS_DIR/$ZIP_NAME"
  else
    ssh -o StrictHostKeyChecking=no "$REMOTE" mkdir -p "$REMOTE_MODS_DIR"
    scp "$ZIP_TMP" "$REMOTE:$REMOTE_MODS_DIR/$ZIP_NAME"
  fi
  if [[ -n "$REMOTE_OWNER" ]]; then
    $DRY_RUN && echo ssh "$REMOTE" chown "$REMOTE_OWNER" "$REMOTE_MODS_DIR/$ZIP_NAME" || \
    ssh -o StrictHostKeyChecking=no "$REMOTE" chown "$REMOTE_OWNER" "$REMOTE_MODS_DIR/$ZIP_NAME"
  fi
  echo "Deployed to $REMOTE:$REMOTE_MODS_DIR/$ZIP_NAME"

  # Restart services if requested
  if [[ "$RESTART" == "true" ]]; then
    # Build unit list
    if [[ -n "$INSTANCES" ]]; then
      IFS=',' read -ra _names <<< "$INSTANCES"
      units=( )
      for n in "${_names[@]}"; do
        n_trimmed="${n// /}"
        [[ -n "$n_trimmed" ]] && units+=("$SYSTEMD_PREFIX-$n_trimmed.service")
      done
    else
      # auto-detect all factorio-*.service
      if $DRY_RUN; then
        echo ssh "$REMOTE" "systemctl list-units --type=service --no-legend '$SYSTEMD_PREFIX-*.service' | awk '{print \\$1}'"
        units=("$SYSTEMD_PREFIX-<auto>.service")
      else
        mapfile -t units < <(ssh -o StrictHostKeyChecking=no "$REMOTE" "systemctl list-units --type=service --no-legend '$SYSTEMD_PREFIX-*.service' | awk '{print \\$1}'")
      fi
    fi

    if [[ ${#units[@]:-0} -eq 0 ]]; then
      echo "No $SYSTEMD_PREFIX-* systemd units found to restart on $REMOTE" >&2
    else
      echo "Restarting units on $REMOTE: ${units[*]}"
      for unit in "${units[@]}"; do
        if $DRY_RUN; then
          echo ssh "$REMOTE" "sudo -n systemctl restart '$unit' || systemctl restart '$unit'"
        else
          ssh -o StrictHostKeyChecking=no "$REMOTE" "sudo -n systemctl restart '$unit' || systemctl restart '$unit'"
        fi
      done
    fi
  fi
fi

# Done
