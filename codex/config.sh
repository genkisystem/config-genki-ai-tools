#!/usr/bin/env sh

set -eu

REPOSITORY_RAW_URL="https://raw.githubusercontent.com/genkisystem/config-genki-ai-tools/main"
FQ_VERSION="0.17.0"

CONFIG_BASE_URL="${GENKI_CONFIG_BASE_URL:-$REPOSITORY_RAW_URL}"
CONFIG_URL="${GENKI_CODEX_CONFIG_URL:-${CONFIG_BASE_URL%/}/codex/config.toml}"
DELETE_URL="${GENKI_CODEX_DELETE_URL:-${CONFIG_BASE_URL%/}/codex/delete.toml}"
CONFIG_PATH="${CODEX_CONFIG_PATH:-${CODEX_HOME:-$HOME/.codex}/config.toml}"

umask 077

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/genki-codex-config.XXXXXX")
ACTIVE_STAGE=""
TTY_STATE=""

cleanup() {
  if [ -n "$TTY_STATE" ]; then
    stty "$TTY_STATE" < /dev/tty >/dev/null 2>&1 || true
  fi
  if [ -n "$ACTIVE_STAGE" ]; then
    rm -f "$ACTIVE_STAGE"
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT HUP INT TERM

log() {
  printf '%s\n' "$*"
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

download() {
  curl -fsSL --retry 3 --connect-timeout 15 "$1" -o "$2"
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    fail "sha256sum or shasum is required to verify fq"
  fi
}

install_fq() {
  if [ -n "${GENKI_FQ_PATH:-}" ]; then
    [ -x "$GENKI_FQ_PATH" ] || fail "GENKI_FQ_PATH is not executable: $GENKI_FQ_PATH"
    FQ_PATH=$GENKI_FQ_PATH
    return
  fi

  os=$(uname -s)
  arch=$(uname -m)

  case "$os/$arch" in
    Darwin/arm64|Darwin/aarch64)
      asset="fq_${FQ_VERSION}_macos_arm64.zip"
      expected="b3007aa0d2ade57eeb21b7cec14ef71ac8adc5ce34221045aece68efd539ff34"
      archive_type="zip"
      ;;
    Darwin/x86_64|Darwin/amd64)
      asset="fq_${FQ_VERSION}_macos_amd64.zip"
      expected="55221b37ad199005777f2e2b00528f2eb6f5cdb74e174a4230d24c6796d61ad8"
      archive_type="zip"
      ;;
    Linux/arm64|Linux/aarch64)
      asset="fq_${FQ_VERSION}_linux_arm64.tar.gz"
      expected="217eba0d2cd03c8cbf9c54e45ecb9700b7100d592b71410ee3628c6d423cd328"
      archive_type="tar"
      ;;
    Linux/x86_64|Linux/amd64)
      asset="fq_${FQ_VERSION}_linux_amd64.tar.gz"
      expected="41c277c59dffacfba9c9f9f4ad3a75bef591d341e40b9ac89fc85acbdf645fee"
      archive_type="tar"
      ;;
    *) fail "fq does not provide a supported binary for $os/$arch" ;;
  esac

  archive="$TMP_DIR/$asset"
  download "https://github.com/wader/fq/releases/download/v${FQ_VERSION}/${asset}" "$archive"
  actual=$(sha256 "$archive")
  [ "$actual" = "$expected" ] || fail "checksum verification failed for $asset"

  extract_dir="$TMP_DIR/fq"
  mkdir -p "$extract_dir"
  if [ "$archive_type" = "zip" ]; then
    command -v unzip >/dev/null 2>&1 || fail "unzip is required to extract fq"
    unzip -q "$archive" -d "$extract_dir"
  else
    command -v tar >/dev/null 2>&1 || fail "tar is required to extract fq"
    tar -xzf "$archive" -C "$extract_dir"
  fi

  FQ_PATH="$extract_dir/fq"
  [ -f "$FQ_PATH" ] || fail "fq executable was not found in $asset"
  chmod +x "$FQ_PATH"
}

backup_file() {
  if [ -f "$CONFIG_PATH" ]; then
    timestamp=$(date '+%Y%m%d%H%M%S')
    backup="${CONFIG_PATH}.bak.${timestamp}"
    if [ -e "$backup" ]; then
      backup="${backup}.$$"
    fi
    cp -p "$CONFIG_PATH" "$backup"
    log "Backup: $backup"
  fi
}

prepare_toml_file() {
  file=$1
  label=$2

  if awk '
    /^[[:space:]]*$/ || /^[[:space:]]*#/ { next }
    { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$file"; then
    if ! "$FQ_PATH" -V '.' "$file" < /dev/null > /dev/null; then
      fail "$label is not valid TOML"
    fi
  else
    printf '{}\n' > "$file"
  fi
}

write_token_input() {
  token_input=$1
  printf 'null\n' > "$token_input"

  token_exists=$(
    "$FQ_PATH" -r '
      has("model_providers")
      and (.model_providers | type == "object")
      and (.model_providers | has("genki"))
      and (.model_providers.genki | type == "object")
      and (.model_providers.genki | has("experimental_bearer_token"))
    ' "$TMP_DIR/current.toml" < /dev/null
  ) || fail "could not inspect the existing Genki provider configuration"

  case "$token_exists" in
    true) return ;;
    false) ;;
    *) fail "could not determine whether the Genki bearer token already exists" ;;
  esac

  if [ "${GENKI_CODEX_EXPERIMENTAL_BEARER_TOKEN+x}" = "x" ]; then
    token=$GENKI_CODEX_EXPERIMENTAL_BEARER_TOKEN
  else
    TTY_STATE=$(stty -g < /dev/tty 2>/dev/null) || \
      fail "a terminal is required to enter the Genki bearer token; set GENKI_CODEX_EXPERIMENTAL_BEARER_TOKEN for non-interactive use"
    printf 'Enter Genki experimental bearer token: ' > /dev/tty
    stty -echo < /dev/tty
    if ! IFS= read -r token < /dev/tty; then
      stty "$TTY_STATE" < /dev/tty
      TTY_STATE=""
      printf '\n' > /dev/tty
      fail "could not read the Genki bearer token"
    fi
    stty "$TTY_STATE" < /dev/tty
    TTY_STATE=""
    printf '\n' > /dev/tty
  fi

  [ -n "$token" ] || fail "the Genki bearer token must not be empty"

  token_raw="$TMP_DIR/token.txt"
  printf '%s' "$token" > "$token_raw"
  chmod 600 "$token_raw"
  if ! "$FQ_PATH" -R -s '.' "$token_raw" < /dev/null > "$token_input"; then
    fail "could not encode the Genki bearer token"
  fi
  rm -f "$token_raw"
  unset token
}

FQ_QUERY='
def manifest_paths:
  def descend($path):
    if type == "object" then
      to_entries[] | .key as $key | .value | descend($path + [$key])
    else
      $path
    end;
  descend([]);

def prune_empty_objects:
  walk(if type == "object" then with_entries(select(.value != {})) else . end);

.[0] as $current
| .[1] as $incoming
| .[3] as $prompted_token
| (
    if $prompted_token == null then
      $incoming
      | delpaths([["model_providers", "genki", "experimental_bearer_token"]])
    else
      $incoming
      | setpath(
          ["model_providers", "genki", "experimental_bearer_token"];
          $prompted_token
        )
    end
  ) as $effective_incoming
| ($current * $effective_incoming) as $merged
| .[2] as $manifest
| reduce ($manifest | manifest_paths) as $path (
    $merged;
    ($manifest | getpath($path)) as $expected
    | (try getpath($path) catch null) as $actual
    | if (
        $expected == "__GENKI_DELETE_ANY__"
        or (($actual | type) == ($expected | type) and $actual == $expected)
      ) then
        delpaths([$path])
      else
        .
      end
  )
| prune_empty_objects
| to_toml
'

command -v curl >/dev/null 2>&1 || fail "curl is required"

log "Downloading managed Codex configuration..."
download "$CONFIG_URL" "$TMP_DIR/config.toml"
download "$DELETE_URL" "$TMP_DIR/delete.toml"
install_fq

target_dir=$(dirname "$CONFIG_PATH")
mkdir -p "$target_dir"

if [ -f "$CONFIG_PATH" ]; then
  cp "$CONFIG_PATH" "$TMP_DIR/current.toml"
else
  : > "$TMP_DIR/current.toml"
fi

prepare_toml_file "$TMP_DIR/current.toml" "the existing Codex config file"
prepare_toml_file "$TMP_DIR/config.toml" "the downloaded Codex config file"
prepare_toml_file "$TMP_DIR/delete.toml" "the downloaded Codex deletion file"
write_token_input "$TMP_DIR/token.json"

ACTIVE_STAGE=$(mktemp "$target_dir/.genki-config.XXXXXX")
if ! "$FQ_PATH" -rjs "$FQ_QUERY" \
  "$TMP_DIR/current.toml" \
  "$TMP_DIR/config.toml" \
  "$TMP_DIR/delete.toml" \
  "$TMP_DIR/token.json" \
  < /dev/null > "$ACTIVE_STAGE"; then
  fail "could not merge Codex config; the existing file was left unchanged"
fi

if ! "$FQ_PATH" -d toml -V '.' "$ACTIVE_STAGE" < /dev/null > /dev/null; then
  fail "could not validate merged Codex config; the existing file was left unchanged"
fi

chmod 600 "$ACTIVE_STAGE"
backup_file
mv -f "$ACTIVE_STAGE" "$CONFIG_PATH"
ACTIVE_STAGE=""

log "Updated: $CONFIG_PATH"
log "Codex configuration installed successfully. Managed values override matching local values."
