#!/usr/bin/env bash
# Shared assertions for deploy script unit tests.

fail() {
  echo "  FAIL: $*" >&2
  FAILURES=$((FAILURES + 1))
}

# check <description> <expected> <actual>
check() {
  CASES=$((CASES + 1))
  if [ "$2" = "$3" ]; then
    echo "  ok: $1"
  else
    fail "$1 — expected '$2', got '$3'"
  fi
}

extract_function() {
  local name="$1" body
  body="$(sed -n "/^${name}()/,/^}/p" "${FUNCTION_SOURCE:?}")"
  case "$body" in
    "") echo "error: could not extract ${name}() from $FUNCTION_SOURCE" >&2; exit 1 ;;
    *$'\n}') ;;
    *) echo "error: extraction of ${name}() from $FUNCTION_SOURCE is not brace-terminated" >&2; exit 1 ;;
  esac
  printf '%s\n' "$body"
}
