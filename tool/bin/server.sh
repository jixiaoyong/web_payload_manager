#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOL_DIR="${ROOT_DIR}/tool"

resolve_dart_cmd() {
  if [[ -n "${DART:-}" ]]; then
    printf '%s\n' "${DART}"
    return 0
  fi

  if command -v fvm >/dev/null 2>&1 && {
    [[ -f "${ROOT_DIR}/.fvmrc" ]] || [[ -f "${ROOT_DIR}/.fvm/fvm_config.json" ]]
  }; then
    printf '%s\n' "fvm dart"
    return 0
  fi

  if command -v flutter >/dev/null 2>&1; then
    local flutter_bin dart_bin
    flutter_bin="$(command -v flutter)"
    dart_bin="$(cd "$(dirname "${flutter_bin}")" && pwd)/dart"
    if [[ -x "${dart_bin}" ]]; then
      printf '%s\n' "${dart_bin}"
      return 0
    fi
  fi

  if command -v dart >/dev/null 2>&1; then
    printf '%s\n' "dart"
    return 0
  fi

  return 1
}

if ! DART_CMD="$(resolve_dart_cmd)"; then
  echo "❌ 未找到 dart。请安装 Flutter SDK，或设置 DART 环境变量。" >&2
  exit 1
fi

cd "${TOOL_DIR}"

if [[ ! -f .dart_tool/package_config.json ]]; then
  echo "ℹ️  首次运行，正在执行 dart pub get ..."
  # shellcheck disable=SC2086
  ${DART_CMD} pub get
fi

# shellcheck disable=SC2086
exec ${DART_CMD} run bin/server.dart "$@"
