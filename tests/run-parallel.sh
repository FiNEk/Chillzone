#!/usr/bin/env bash
# Полный набор в независимых процессах. Любой отказ даёт ненулевой код всему прогону.
set -euo pipefail
interpreter="${1-lua5.1}"
jobs="${2-4}"
if [[ $# -gt 2 || ! "$jobs" =~ ^[1-9][0-9]?$ ]] || (( jobs > 64 )); then
    printf 'Запуск: bash tests/run-parallel.sh [lua5.1|luajit] [число процессов от 1 до 64]\n' >&2
    exit 2
fi
if ! resolved="$(command -v "$interpreter")"; then
    printf 'Не найден интерпретатор: %s\n' "$interpreter" >&2
    exit 2
fi
if [[ "$resolved" != /* ]]; then
    resolved="$(cd -- "$(dirname -- "$resolved")" && pwd)/$(basename -- "$resolved")"
fi
interpreter="$resolved"
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
logs="$(mktemp -d)"
pids=()
# Вызывается через trap; ShellCheck не отслеживает такой вызов.
# shellcheck disable=SC2329
cleanup() {
    local index
    trap '' INT TERM
    for pid in "${pids[@]}"; do if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || :; fi; done
    for pid in "${pids[@]}"; do if [[ -n "$pid" ]]; then wait "$pid" 2>/dev/null || :; fi; done
    for ((index = 1; index <= jobs; index++)); do rm -f -- "$logs/$index.log"; done
    rmdir -- "$logs"
}
trap 'cleanup' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
for ((index = 1; index <= jobs; index++)); do
    CZ_TEST_SHARD_INDEX="$index" CZ_TEST_SHARD_COUNT="$jobs" \
        "$interpreter" tests/run.lua > "$logs/$index.log" 2>&1 &
    pids+=("$!")
done
status=0
for ((index = 1; index <= jobs; index++)); do
    code=0
    wait "${pids[index - 1]}" || code=$?
    pids[index - 1]=''
    printf '\nЧасть %s/%s\n' "$index" "$jobs"
    cat -- "$logs/$index.log"
    if (( code != 0 )); then
        printf 'Часть %s завершилась с кодом %s\n' "$index" "$code" >&2
        status=1
    fi
done
exit "$status"
