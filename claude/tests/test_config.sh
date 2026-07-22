#!/usr/bin/env sh

set -eu

CLAUDE_DIR=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
FQ_PATH=${GENKI_FQ_PATH:-}
export GENKI_CLAUDE_ANTHROPIC_AUTH_TOKEN='test-anthropic-token'
export GENKI_CLAUDE_ANTHROPIC_BASE_URL='https://claude.test.example'

if [ -z "$FQ_PATH" ] || [ ! -x "$FQ_PATH" ]; then
  printf 'Set GENKI_FQ_PATH to an executable fq v0.17.0 binary.\n' >&2
  exit 1
fi

TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/genki-claude-test.XXXXXX")
trap 'rm -rf "$TEST_HOME"' EXIT HUP INT TERM

mkdir -p "$TEST_HOME/.claude"
cp "$CLAUDE_DIR/tests/fixtures/current/settings.json" "$TEST_HOME/.claude/settings.json"

HOME="$TEST_HOME" \
GENKI_CLAUDE_SETTINGS_URL="file://$CLAUDE_DIR/tests/fixtures/source/settings.json" \
GENKI_CLAUDE_DELETE_URL="file://$CLAUDE_DIR/tests/fixtures/source/delete.json" \
GENKI_FQ_PATH="$FQ_PATH" \
  sh "$CLAUDE_DIR/config.sh"

diff -u "$CLAUDE_DIR/tests/fixtures/expected/settings.json" "$TEST_HOME/.claude/settings.json"
test "$(find "$TEST_HOME/.claude" -name 'settings.json.bak.*' | wc -l | tr -d ' ')" = "1"

HOME="$TEST_HOME" \
GENKI_CLAUDE_SETTINGS_URL="file://$CLAUDE_DIR/tests/fixtures/source/settings.json" \
GENKI_CLAUDE_DELETE_URL="file://$CLAUDE_DIR/tests/fixtures/mismatch/delete.json" \
GENKI_CLAUDE_ANTHROPIC_AUTH_TOKEN="must-not-overwrite-existing" \
GENKI_CLAUDE_ANTHROPIC_BASE_URL="https://must-not-overwrite.example" \
GENKI_FQ_PATH="$FQ_PATH" \
  sh "$CLAUDE_DIR/config.sh"

diff -u "$CLAUDE_DIR/tests/fixtures/expected/settings.json" "$TEST_HOME/.claude/settings.json"
test "$(find "$TEST_HOME/.claude" -name 'settings.json.bak.*' | wc -l | tr -d ' ')" = "2"

HOME="$TEST_HOME" \
GENKI_CLAUDE_SETTINGS_URL="file://$CLAUDE_DIR/tests/fixtures/source/settings.json" \
GENKI_CLAUDE_DELETE_URL="file://$CLAUDE_DIR/tests/fixtures/delete/delete.json" \
GENKI_FQ_PATH="$FQ_PATH" \
  sh "$CLAUDE_DIR/config.sh"

diff -u "$CLAUDE_DIR/tests/fixtures/expected/deleted.json" "$TEST_HOME/.claude/settings.json"
test "$(find "$TEST_HOME/.claude" -name 'settings.json.bak.*' | wc -l | tr -d ' ')" = "3"

HOME="$TEST_HOME" \
GENKI_CLAUDE_SETTINGS_URL="file://$CLAUDE_DIR/tests/fixtures/source/settings.json" \
GENKI_CLAUDE_DELETE_URL="file://$CLAUDE_DIR/tests/fixtures/delete-any/delete.json" \
GENKI_FQ_PATH="$FQ_PATH" \
  sh "$CLAUDE_DIR/config.sh"

diff -u "$CLAUDE_DIR/tests/fixtures/expected/deleted.json" "$TEST_HOME/.claude/settings.json"
test "$(find "$TEST_HOME/.claude" -name 'settings.json.bak.*' | wc -l | tr -d ' ')" = "4"

HOME="$TEST_HOME" \
GENKI_CLAUDE_SETTINGS_URL="file://$CLAUDE_DIR/tests/fixtures/source/settings.json" \
GENKI_CLAUDE_DELETE_URL="file://$CLAUDE_DIR/tests/fixtures/delete-object/delete.json" \
GENKI_FQ_PATH="$FQ_PATH" \
  sh "$CLAUDE_DIR/config.sh"

diff -u "$CLAUDE_DIR/tests/fixtures/expected/deleted-object.json" "$TEST_HOME/.claude/settings.json"
test "$(find "$TEST_HOME/.claude" -name 'settings.json.bak.*' | wc -l | tr -d ' ')" = "5"

if HOME="$TEST_HOME" \
  GENKI_CLAUDE_SETTINGS_URL="file://$CLAUDE_DIR/tests/fixtures/invalid/settings.json" \
  GENKI_CLAUDE_DELETE_URL="file://$CLAUDE_DIR/tests/fixtures/source/delete.json" \
  GENKI_FQ_PATH="$FQ_PATH" \
  sh "$CLAUDE_DIR/config.sh" >/dev/null 2>&1; then
  printf 'Claude installer unexpectedly accepted invalid JSON.\n' >&2
  exit 1
fi

diff -u "$CLAUDE_DIR/tests/fixtures/expected/deleted-object.json" "$TEST_HOME/.claude/settings.json"
test "$(find "$TEST_HOME/.claude" -name 'settings.json.bak.*' | wc -l | tr -d ' ')" = "5"

COMMENT_HOME="$TEST_HOME/comment"
COMMENT_OUTPUT="$TEST_HOME/comment-output.log"
mkdir -p "$COMMENT_HOME/.claude"
cp "$CLAUDE_DIR/tests/fixtures/comment/settings.json" "$COMMENT_HOME/.claude/settings.json"

if HOME="$COMMENT_HOME" \
  GENKI_CLAUDE_SETTINGS_URL="file://$CLAUDE_DIR/tests/fixtures/source/settings.json" \
  GENKI_CLAUDE_DELETE_URL="file://$CLAUDE_DIR/tests/fixtures/source/delete.json" \
  GENKI_FQ_PATH="$FQ_PATH" \
  sh "$CLAUDE_DIR/config.sh" >"$COMMENT_OUTPUT" 2>&1; then
  printf 'Claude installer unexpectedly accepted JSON comments.\n' >&2
  exit 1
fi

grep -F 'Error: the existing Claude settings file is not a valid JSON object' "$COMMENT_OUTPUT" >/dev/null
diff -u "$CLAUDE_DIR/tests/fixtures/comment/settings.json" "$COMMENT_HOME/.claude/settings.json"
test "$(find "$COMMENT_HOME/.claude" -name 'settings.json.bak.*' | wc -l | tr -d ' ')" = "0"

DUPLICATE_HOME="$TEST_HOME/duplicate-hook"
mkdir -p "$DUPLICATE_HOME/.claude"
cp "$CLAUDE_DIR/tests/fixtures/duplicate-hook/settings.json" "$DUPLICATE_HOME/.claude/settings.json"

if HOME="$DUPLICATE_HOME" \
  GENKI_CLAUDE_SETTINGS_URL="file://$CLAUDE_DIR/tests/fixtures/source/settings.json" \
  GENKI_CLAUDE_DELETE_URL="file://$CLAUDE_DIR/tests/fixtures/source/delete.json" \
  GENKI_FQ_PATH="$FQ_PATH" \
  sh "$CLAUDE_DIR/config.sh" >/dev/null 2>&1; then
  printf 'Claude installer unexpectedly accepted duplicate GENKI_HOOK_ID values.\n' >&2
  exit 1
fi

diff -u "$CLAUDE_DIR/tests/fixtures/duplicate-hook/settings.json" "$DUPLICATE_HOME/.claude/settings.json"
test "$(find "$DUPLICATE_HOME/.claude" -name 'settings.json.bak.*' | wc -l | tr -d ' ')" = "0"

APPEND_HOME="$TEST_HOME/append-hook"
mkdir -p "$APPEND_HOME/.claude"
cp "$CLAUDE_DIR/tests/fixtures/append-hook/settings.json" "$APPEND_HOME/.claude/settings.json"

HOME="$APPEND_HOME" \
GENKI_CLAUDE_SETTINGS_URL="file://$CLAUDE_DIR/tests/fixtures/source/settings.json" \
GENKI_CLAUDE_DELETE_URL="file://$CLAUDE_DIR/tests/fixtures/source/delete.json" \
GENKI_FQ_PATH="$FQ_PATH" \
  sh "$CLAUDE_DIR/config.sh"

test "$("$FQ_PATH" -r '[.hooks.PreToolUse[].hooks[].command | select(startswith("GENKI_HOOK_ID=deny_nested_agent;"))] | length' "$APPEND_HOME/.claude/settings.json")" = "1"
test "$("$FQ_PATH" -r '[.hooks.PreToolUse[].hooks[].command | select(startswith("GENKI_HOOK_ID=deny_nested_agent_2;"))] | length' "$APPEND_HOME/.claude/settings.json")" = "1"
test "$("$FQ_PATH" -r '[.hooks.PreToolUse[].hooks[].command | select(. == "existing-bash-hook")] | length' "$APPEND_HOME/.claude/settings.json")" = "1"
test "$(find "$APPEND_HOME/.claude" -name 'settings.json.bak.*' | wc -l | tr -d ' ')" = "1"

EMPTY_BASE_URL_HOME="$TEST_HOME/empty-base-url"
mkdir -p "$EMPTY_BASE_URL_HOME/.claude"
cp "$CLAUDE_DIR/tests/fixtures/empty-base-url/settings.json" "$EMPTY_BASE_URL_HOME/.claude/settings.json"

HOME="$EMPTY_BASE_URL_HOME" \
GENKI_CLAUDE_SETTINGS_URL="file://$CLAUDE_DIR/tests/fixtures/source/settings.json" \
GENKI_CLAUDE_DELETE_URL="file://$CLAUDE_DIR/tests/fixtures/source/delete.json" \
GENKI_CLAUDE_ANTHROPIC_BASE_URL="https://claude.empty-replacement.example" \
GENKI_FQ_PATH="$FQ_PATH" \
  sh "$CLAUDE_DIR/config.sh"

test "$("$FQ_PATH" -r '.env.ANTHROPIC_BASE_URL' "$EMPTY_BASE_URL_HOME/.claude/settings.json")" = "https://claude.empty-replacement.example"
test "$("$FQ_PATH" -r '.env.ANTHROPIC_AUTH_TOKEN' "$EMPTY_BASE_URL_HOME/.claude/settings.json")" = "existing-token"

EMPTY_INPUT_HOME="$TEST_HOME/empty-input"
mkdir -p "$EMPTY_INPUT_HOME/.claude"
cp "$CLAUDE_DIR/tests/fixtures/empty-input/settings.json" "$EMPTY_INPUT_HOME/.claude/settings.json"

HOME="$EMPTY_INPUT_HOME" \
GENKI_CLAUDE_SETTINGS_URL="file://$CLAUDE_DIR/tests/fixtures/source/settings.json" \
GENKI_CLAUDE_DELETE_URL="file://$CLAUDE_DIR/tests/fixtures/source/delete.json" \
GENKI_CLAUDE_ANTHROPIC_AUTH_TOKEN='' \
GENKI_CLAUDE_ANTHROPIC_BASE_URL='' \
GENKI_FQ_PATH="$FQ_PATH" \
  sh "$CLAUDE_DIR/config.sh"

test "$("$FQ_PATH" -r '.env.ANTHROPIC_BASE_URL' "$EMPTY_INPUT_HOME/.claude/settings.json")" = ""
test "$("$FQ_PATH" -r '.env | has("ANTHROPIC_AUTH_TOKEN")' "$EMPTY_INPUT_HOME/.claude/settings.json")" = "false"

PIPE_HOME="$TEST_HOME/pipe"
mkdir -p "$PIPE_HOME/.claude"
cp "$CLAUDE_DIR/tests/fixtures/current/settings.json" "$PIPE_HOME/.claude/settings.json"

curl -fsSL "file://$CLAUDE_DIR/config.sh" | \
  HOME="$PIPE_HOME" \
  GENKI_CLAUDE_SETTINGS_URL="file://$CLAUDE_DIR/tests/fixtures/source/settings.json" \
  GENKI_CLAUDE_DELETE_URL="file://$CLAUDE_DIR/tests/fixtures/source/delete.json" \
  GENKI_FQ_PATH="$FQ_PATH" \
  sh

diff -u "$CLAUDE_DIR/tests/fixtures/expected/settings.json" "$PIPE_HOME/.claude/settings.json"
test "$(find "$PIPE_HOME/.claude" -name 'settings.json.bak.*' | wc -l | tr -d ' ')" = "1"

printf 'Claude installer test passed.\n'
