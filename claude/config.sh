#!/usr/bin/env sh

set -eu

REPOSITORY_RAW_URL="https://raw.githubusercontent.com/genkisystem/config-genki-ai-tools/main"
FQ_VERSION="0.17.0"

CONFIG_BASE_URL="${GENKI_CONFIG_BASE_URL:-$REPOSITORY_RAW_URL}"
SETTINGS_URL="${GENKI_CLAUDE_SETTINGS_URL:-${CONFIG_BASE_URL%/}/claude/settings.json}"
DELETE_URL="${GENKI_CLAUDE_DELETE_URL:-${CONFIG_BASE_URL%/}/claude/delete.json}"
SETTINGS_PATH="${CLAUDE_SETTINGS_PATH:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json}"

umask 077

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/genki-claude-config.XXXXXX")
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
  if [ -f "$SETTINGS_PATH" ]; then
    timestamp=$(date '+%Y%m%d%H%M%S')
    backup="${SETTINGS_PATH}.bak.${timestamp}"
    if [ -e "$backup" ]; then
      backup="${backup}.$$"
    fi
    cp -p "$SETTINGS_PATH" "$backup"
    log "Backup: $backup"
  fi
}

write_token_input() {
  token_input=$1
  printf 'null\n' > "$token_input"

  token_exists=$(
    "$FQ_PATH" -r '
      has("env")
      and (.env | type == "object")
      and (.env | has("ANTHROPIC_AUTH_TOKEN"))
    ' "$TMP_DIR/current.json" < /dev/null
  ) || fail "could not inspect the existing Claude authentication configuration"

  case "$token_exists" in
    true) return ;;
    false) ;;
    *) fail "could not determine whether ANTHROPIC_AUTH_TOKEN already exists" ;;
  esac

  if [ "${GENKI_CLAUDE_ANTHROPIC_AUTH_TOKEN+x}" = "x" ]; then
    token=$GENKI_CLAUDE_ANTHROPIC_AUTH_TOKEN
  else
    TTY_STATE=$(stty -g < /dev/tty 2>/dev/null) || \
      fail "a terminal is required to enter ANTHROPIC_AUTH_TOKEN; set GENKI_CLAUDE_ANTHROPIC_AUTH_TOKEN for non-interactive use"
    printf 'Enter Claude ANTHROPIC_AUTH_TOKEN: ' > /dev/tty
    stty -echo < /dev/tty
    if ! IFS= read -r token < /dev/tty; then
      stty "$TTY_STATE" < /dev/tty
      TTY_STATE=""
      printf '\n' > /dev/tty
      fail "could not read ANTHROPIC_AUTH_TOKEN"
    fi
    stty "$TTY_STATE" < /dev/tty
    TTY_STATE=""
    printf '\n' > /dev/tty
  fi

  [ -n "$token" ] || fail "ANTHROPIC_AUTH_TOKEN must not be empty"

  token_raw="$TMP_DIR/token.txt"
  printf '%s' "$token" > "$token_raw"
  chmod 600 "$token_raw"
  if ! "$FQ_PATH" -R -s '.' "$token_raw" < /dev/null > "$token_input"; then
    fail "could not encode ANTHROPIC_AUTH_TOKEN"
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

def block_anchor_id:
  [
    .hooks[]?
    | select(.type? == "command")
    | .command?
    | select(type == "string")
    | select(contains("GENKI_HOOK_ID="))
    | if test("GENKI_HOOK_ID=[A-Za-z0-9_-]+;") then
        split("GENKI_HOOK_ID=")[1] | split(";")[0]
      else
        error("invalid GENKI_HOOK_ID marker")
      end
  ] as $ids
  | if ($ids | length) == 0 then
      null
    elif ($ids | length) == 1 then
      $ids[0]
    else
      error("a managed hook matcher block must contain exactly one GENKI_HOOK_ID")
    end;

def managed_hook_blocks:
  (.hooks // {})
  | if type == "object" then . else error("settings.hooks must be an object") end
  | to_entries[]
  | if (.value | type) == "array" then . else error("each hook event must be an array") end
  | .key as $event
  | .value[]
  | . as $block
  | (block_anchor_id) as $id
  | select($id != null)
  | {event: $event, id: $id, block: $block};

def without_managed_hook_blocks:
  . as $settings
  | reduce ((.hooks // {}) | keys[]) as $event (
      $settings;
      (.hooks[$event] | map(select(block_anchor_id == null))) as $regular_blocks
      | if ($regular_blocks | length) == 0 then
          del(.hooks[$event])
        else
          .hooks[$event] = $regular_blocks
        end
    )
  | if .hooks? == {} then del(.hooks) else . end;

def matching_hook_blocks($settings; $id):
  [
    ($settings.hooks // {} | to_entries[]) as $event
    | ($event.value | to_entries[]) as $indexed_block
    | $indexed_block.value.hooks[]?
    | select(.type? == "command")
    | .command?
    | select(type == "string")
    | select(contains("GENKI_HOOK_ID=" + $id + ";"))
    | {event: $event.key, index: $indexed_block.key}
  ];

def append_hook_block($event; $block):
  if .hooks? == null then .hooks = {} else . end
  | if .hooks[$event]? == null then .hooks[$event] = [] else . end
  | .hooks[$event] += [$block];

def remove_hook_block($event; $index):
  delpaths([["hooks", $event, $index]])
  | if (.hooks[$event] | length) == 0 then del(.hooks[$event]) else . end
  | if .hooks == {} then del(.hooks) else . end;

def upsert_managed_hook_blocks($settings; $managed_blocks):
  reduce $managed_blocks[] as $managed (
    $settings;
    (matching_hook_blocks(.; $managed.id)) as $matches
    | if ($matches | length) > 1 then
        error("duplicate GENKI_HOOK_ID=" + $managed.id)
      elif ($matches | length) == 0 then
        append_hook_block($managed.event; $managed.block)
      else
        $matches[0] as $match
        | if $match.event == $managed.event then
            setpath(["hooks", $match.event, $match.index]; $managed.block)
          else
            remove_hook_block($match.event; $match.index)
            | append_hook_block($managed.event; $managed.block)
          end
      end
  );

.[0] as $current
| .[1] as $incoming
| .[3] as $prompted_token
| (
    if $prompted_token == null then
      $incoming
      | delpaths([["env", "ANTHROPIC_AUTH_TOKEN"]])
    else
      $incoming
      | setpath(["env", "ANTHROPIC_AUTH_TOKEN"]; $prompted_token)
    end
  ) as $effective_incoming
| ($effective_incoming | [managed_hook_blocks]) as $managed_blocks
| if (($managed_blocks | map(.id) | unique | length) != ($managed_blocks | length)) then
    error("duplicate GENKI_HOOK_ID in managed Claude settings")
  else
    .
  end
| reduce $managed_blocks[] as $managed (
    $current;
    if (matching_hook_blocks($current; $managed.id) | length) > 1 then
      error("duplicate GENKI_HOOK_ID=" + $managed.id + " in current Claude settings")
    else
      .
    end
  ) as $validated_current
| ($effective_incoming | without_managed_hook_blocks) as $regular_incoming
| ($validated_current * $regular_incoming) as $base_merged
| upsert_managed_hook_blocks($base_merged; $managed_blocks) as $merged
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
'

command -v curl >/dev/null 2>&1 || fail "curl is required"

log "Downloading managed Claude configuration..."
download "$SETTINGS_URL" "$TMP_DIR/settings.json"
download "$DELETE_URL" "$TMP_DIR/delete.json"
install_fq

target_dir=$(dirname "$SETTINGS_PATH")
mkdir -p "$target_dir"

if [ -f "$SETTINGS_PATH" ]; then
  cp "$SETTINGS_PATH" "$TMP_DIR/current.json"
else
  printf '{}\n' > "$TMP_DIR/current.json"
fi

if ! "$FQ_PATH" -V '.' "$TMP_DIR/current.json" < /dev/null > /dev/null; then
  fail "the existing Claude settings file is not valid JSON"
fi
if ! "$FQ_PATH" -V '.' "$TMP_DIR/settings.json" < /dev/null > /dev/null; then
  fail "the downloaded Claude settings file is not valid JSON"
fi
if ! "$FQ_PATH" -V '.' "$TMP_DIR/delete.json" < /dev/null > /dev/null; then
  fail "the downloaded Claude deletion file is not valid JSON"
fi
write_token_input "$TMP_DIR/token.json"

ACTIVE_STAGE=$(mktemp "$target_dir/.genki-config.XXXXXX")
if ! "$FQ_PATH" -d json -Vs "$FQ_QUERY" \
  "$TMP_DIR/current.json" \
  "$TMP_DIR/settings.json" \
  "$TMP_DIR/delete.json" \
  "$TMP_DIR/token.json" \
  < /dev/null > "$ACTIVE_STAGE"; then
  fail "could not merge Claude settings; the existing file was left unchanged"
fi

if ! "$FQ_PATH" -d json -V '.' "$ACTIVE_STAGE" < /dev/null > /dev/null; then
  fail "could not validate merged Claude settings; the existing file was left unchanged"
fi

chmod 600 "$ACTIVE_STAGE"
backup_file
mv -f "$ACTIVE_STAGE" "$SETTINGS_PATH"
ACTIVE_STAGE=""

log "Updated: $SETTINGS_PATH"
log "Claude configuration installed successfully. Managed values override matching local values."
