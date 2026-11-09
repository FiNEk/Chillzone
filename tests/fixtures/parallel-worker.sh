#!/usr/bin/env bash
# Поддельный интерпретатор для проверки ожидания процессов и передачи кода ошибки.
set -eu
index="$CZ_TEST_SHARD_INDEX"
if [[ "${CZ_FIXTURE_WAIT:-0}" == 1 ]]; then
    printf '%s\n' "$BASHPID" > "$CZ_FIXTURE_OUT/$index"
    exec sleep 30
fi
if [[ "$index" == "${CZ_FIXTURE_FAIL:-0}" ]]; then exit 7; fi
if [[ "$index" == 4 ]]; then sleep 0.3; else sleep 0.05; fi
printf '%s/%s\n' "$index" "$CZ_TEST_SHARD_COUNT" > "$CZ_FIXTURE_OUT/$index"
printf 'завершена часть %s\n' "$index"
