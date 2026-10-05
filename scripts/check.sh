#!/usr/bin/env bash
# Static quality gate: format check, Roblox-aware type check, and a full place build.
# Tools are looked up on PATH, then in $TOOLS_DIR (default: ./.tools).
set -uo pipefail
cd "$(dirname "$0")/.."
TOOLS_DIR="${TOOLS_DIR:-$PWD/.tools}"
export PATH="$PATH:$TOOLS_DIR"
DEFS="$TOOLS_DIR/globalTypes.d.luau"
if [ ! -f "$DEFS" ]; then
  mkdir -p "$TOOLS_DIR"
  curl -sSL -o "$DEFS" https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/scripts/globalTypes.d.luau
fi
status=0
TMP_OUT="$(mktemp)"; STY_OUT="$(mktemp)"; SRCMAP="$(mktemp --suffix=.json)"
trap 'rm -f "$TMP_OUT" "$STY_OUT" "$SRCMAP"' EXIT

echo "== stylua =="
if [ "${FIX:-0}" = "1" ]; then stylua src; fi
stylua --check src >"$STY_OUT" 2>&1 || { head -40 "$STY_OUT"; echo "stylua: formatting issues (run FIX=1 scripts/check.sh)"; status=1; }

echo "== rojo sourcemap =="
rojo sourcemap default.project.json -o "$SRCMAP" || status=1
cp "$SRCMAP" sourcemap.json 2>/dev/null || true

echo "== luau-lsp analyze =="
luau-lsp analyze --definitions="$DEFS" --sourcemap="$SRCMAP" --base-luaurc=.luaurc \
  --ignore="**/_Index/**" src "$@" 2>&1 | tee "$TMP_OUT" | tail -80
if grep -qE "TypeError|SyntaxError|Error" "$TMP_OUT"; then
  echo "luau-lsp: $(grep -cE 'TypeError|SyntaxError' "$TMP_OUT") error(s)"; status=1
fi

echo "== rojo build =="
mkdir -p build
rojo build default.project.json -o "build/WW2-Frontlines-$$.rbxl" && mv -f "build/WW2-Frontlines-$$.rbxl" build/WW2-Frontlines.rbxl || status=1

[ $status -eq 0 ] && echo "ALL CHECKS PASSED" || echo "CHECKS FAILED"
exit $status
