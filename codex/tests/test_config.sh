#!/usr/bin/env sh

set -eu

CODEX_DIR=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
FQ_PATH=${GENKI_FQ_PATH:-}
export GENKI_CODEX_EXPERIMENTAL_BEARER_TOKEN='test-bearer-token'
export GENKI_CODEX_PROVIDER_BASE_URL='https://codex.test.example/v1'

if [ -z "$FQ_PATH" ] || [ ! -x "$FQ_PATH" ]; then
  printf 'Set GENKI_FQ_PATH to an executable fq v0.17.0 binary.\n' >&2
  exit 1
fi

TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/genki-codex-test.XXXXXX")
trap 'rm -rf "$TEST_HOME"' EXIT HUP INT TERM

mkdir -p "$TEST_HOME/.codex"
cp "$CODEX_DIR/tests/fixtures/current/config.toml" "$TEST_HOME/.codex/config.toml"

HOME="$TEST_HOME" \
GENKI_CODEX_CONFIG_URL="file://$CODEX_DIR/tests/fixtures/source/config.toml" \
GENKI_CODEX_DELETE_URL="file://$CODEX_DIR/tests/fixtures/source/delete.toml" \
GENKI_FQ_PATH="$FQ_PATH" \
  sh "$CODEX_DIR/config.sh"

diff -u "$CODEX_DIR/tests/fixtures/expected/config.toml" "$TEST_HOME/.codex/config.toml"
test "$(find "$TEST_HOME/.codex" -name 'config.toml.bak.*' | wc -l | tr -d ' ')" = "1"

HOME="$TEST_HOME" \
GENKI_CODEX_CONFIG_URL="file://$CODEX_DIR/tests/fixtures/source/config.toml" \
GENKI_CODEX_DELETE_URL="file://$CODEX_DIR/tests/fixtures/mismatch/delete.toml" \
GENKI_CODEX_EXPERIMENTAL_BEARER_TOKEN="must-not-overwrite-existing" \
GENKI_CODEX_PROVIDER_BASE_URL="https://must-not-overwrite.example/v1" \
GENKI_FQ_PATH="$FQ_PATH" \
  sh "$CODEX_DIR/config.sh"

diff -u "$CODEX_DIR/tests/fixtures/expected/config.toml" "$TEST_HOME/.codex/config.toml"
test "$(find "$TEST_HOME/.codex" -name 'config.toml.bak.*' | wc -l | tr -d ' ')" = "2"

HOME="$TEST_HOME" \
GENKI_CODEX_CONFIG_URL="file://$CODEX_DIR/tests/fixtures/source/config.toml" \
GENKI_CODEX_DELETE_URL="file://$CODEX_DIR/tests/fixtures/delete/delete.toml" \
GENKI_FQ_PATH="$FQ_PATH" \
  sh "$CODEX_DIR/config.sh"

diff -u "$CODEX_DIR/tests/fixtures/expected/deleted.toml" "$TEST_HOME/.codex/config.toml"
test "$(find "$TEST_HOME/.codex" -name 'config.toml.bak.*' | wc -l | tr -d ' ')" = "3"

HOME="$TEST_HOME" \
GENKI_CODEX_CONFIG_URL="file://$CODEX_DIR/tests/fixtures/source/config.toml" \
GENKI_CODEX_DELETE_URL="file://$CODEX_DIR/tests/fixtures/delete-any/delete.toml" \
GENKI_FQ_PATH="$FQ_PATH" \
  sh "$CODEX_DIR/config.sh"

diff -u "$CODEX_DIR/tests/fixtures/expected/deleted.toml" "$TEST_HOME/.codex/config.toml"
test "$(find "$TEST_HOME/.codex" -name 'config.toml.bak.*' | wc -l | tr -d ' ')" = "4"

EMPTY_BASE_URL_HOME="$TEST_HOME/empty-base-url"
mkdir -p "$EMPTY_BASE_URL_HOME/.codex"
cp "$CODEX_DIR/tests/fixtures/empty-base-url/config.toml" "$EMPTY_BASE_URL_HOME/.codex/config.toml"

HOME="$EMPTY_BASE_URL_HOME" \
GENKI_CODEX_CONFIG_URL="file://$CODEX_DIR/tests/fixtures/source/config.toml" \
GENKI_CODEX_DELETE_URL="file://$CODEX_DIR/tests/fixtures/source/delete.toml" \
GENKI_CODEX_PROVIDER_BASE_URL="https://codex.empty-replacement.example/v1" \
GENKI_FQ_PATH="$FQ_PATH" \
  sh "$CODEX_DIR/config.sh"

test "$("$FQ_PATH" -r '.model_providers.genki.base_url' "$EMPTY_BASE_URL_HOME/.codex/config.toml")" = "https://codex.empty-replacement.example/v1"
test "$("$FQ_PATH" -r '.model_providers.genki.experimental_bearer_token' "$EMPTY_BASE_URL_HOME/.codex/config.toml")" = "existing-token"

EMPTY_INPUT_HOME="$TEST_HOME/empty-input"
mkdir -p "$EMPTY_INPUT_HOME/.codex"
cp "$CODEX_DIR/tests/fixtures/empty-input/config.toml" "$EMPTY_INPUT_HOME/.codex/config.toml"

HOME="$EMPTY_INPUT_HOME" \
GENKI_CODEX_CONFIG_URL="file://$CODEX_DIR/tests/fixtures/source/config.toml" \
GENKI_CODEX_DELETE_URL="file://$CODEX_DIR/tests/fixtures/source/delete.toml" \
GENKI_CODEX_EXPERIMENTAL_BEARER_TOKEN='' \
GENKI_CODEX_PROVIDER_BASE_URL='' \
GENKI_FQ_PATH="$FQ_PATH" \
  sh "$CODEX_DIR/config.sh"

test "$("$FQ_PATH" -r '.model_providers.genki.base_url' "$EMPTY_INPUT_HOME/.codex/config.toml")" = ""
test "$("$FQ_PATH" -r '.model_providers.genki | has("experimental_bearer_token")' "$EMPTY_INPUT_HOME/.codex/config.toml")" = "false"

if HOME="$TEST_HOME" \
  GENKI_CODEX_CONFIG_URL="file://$CODEX_DIR/tests/fixtures/invalid/config.toml" \
  GENKI_CODEX_DELETE_URL="file://$CODEX_DIR/tests/fixtures/source/delete.toml" \
  GENKI_FQ_PATH="$FQ_PATH" \
  sh "$CODEX_DIR/config.sh" >/dev/null 2>&1; then
  printf 'Codex installer unexpectedly accepted invalid TOML.\n' >&2
  exit 1
fi

diff -u "$CODEX_DIR/tests/fixtures/expected/deleted.toml" "$TEST_HOME/.codex/config.toml"
test "$(find "$TEST_HOME/.codex" -name 'config.toml.bak.*' | wc -l | tr -d ' ')" = "4"

PIPE_HOME="$TEST_HOME/pipe"
mkdir -p "$PIPE_HOME/.codex"
cp "$CODEX_DIR/tests/fixtures/current/config.toml" "$PIPE_HOME/.codex/config.toml"

curl -fsSL "file://$CODEX_DIR/config.sh" | \
  HOME="$PIPE_HOME" \
  GENKI_CODEX_CONFIG_URL="file://$CODEX_DIR/tests/fixtures/source/config.toml" \
  GENKI_CODEX_DELETE_URL="file://$CODEX_DIR/tests/fixtures/source/delete.toml" \
  GENKI_FQ_PATH="$FQ_PATH" \
  sh

diff -u "$CODEX_DIR/tests/fixtures/expected/config.toml" "$PIPE_HOME/.codex/config.toml"
test "$(find "$PIPE_HOME/.codex" -name 'config.toml.bak.*' | wc -l | tr -d ' ')" = "1"

printf 'Codex installer test passed.\n'
