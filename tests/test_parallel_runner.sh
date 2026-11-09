#!/usr/bin/env bash
# Проверка запуска из другого каталога, путей с пробелами и отказа одного процесса.
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
temp="$(mktemp -d)"
cleanup() {
    rm -f -- "$temp/fake lua" "$temp/success.log" "$temp/failure.log" "$temp/invalid.log"
    for index in 1 2 3 4; do rm -f -- "$temp/$index"; done
    rmdir -- "$temp"
}
trap 'cleanup' EXIT
cp -- "$root/tests/fixtures/parallel-worker.sh" "$temp/fake lua"
chmod +x "$temp/fake lua"
cd -- "$temp"
export CZ_FIXTURE_OUT="$temp"
bash "$root/tests/run-parallel.sh" "$temp/fake lua" 4 > "$temp/success.log" 2>&1
for index in 1 2 3 4; do
    [[ "$(cat "$temp/$index")" == "$index/4" ]]
    rm -- "$temp/$index"
done
bash "$root/tests/run-parallel.sh" './fake lua' 4 > "$temp/success.log" 2>&1
for index in 1 2 3 4; do [[ "$(cat "$temp/$index")" == "$index/4" ]]; rm -- "$temp/$index"; done
if CZ_FIXTURE_FAIL=2 bash "$root/tests/run-parallel.sh" "$temp/fake lua" 4 > "$temp/failure.log" 2>&1; then
    printf 'Ошибка части была потеряна\n' >&2
    exit 1
fi
[[ ! -e "$temp/2" ]]
for index in 1 3 4; do [[ "$(cat "$temp/$index")" == "$index/4" ]]; done
for jobs in 0 -1 1.5 bad 999999999999999999999; do
    if bash "$root/tests/run-parallel.sh" "$temp/fake lua" "$jobs" > "$temp/invalid.log" 2>&1; then
        printf 'Неверное число процессов принято\n' >&2
        exit 1
    fi
done
if bash "$root/tests/run-parallel.sh" "$temp/absent" 4 > "$temp/invalid.log" 2>&1; then exit 1; fi
for index in 1 2 3 4; do rm -f -- "$temp/$index"; done
CZ_FIXTURE_WAIT=1 bash "$root/tests/run-parallel.sh" "$temp/fake lua" 4 > "$temp/success.log" 2>&1 &
launcher=$!
for _ in {1..100}; do
    if [[ -s "$temp/1" && -s "$temp/2" && -s "$temp/3" && -s "$temp/4" ]]; then break; fi
    sleep 0.05
done
kill -TERM "$launcher"
if wait "$launcher"; then exit 1; fi
for index in 1 2 3 4; do
    pid="$(cat "$temp/$index")"
    if kill -0 "$pid" 2>/dev/null; then printf 'После отмены остался процесс\n' >&2; exit 1; fi
done
printf 'Запуск процессов, пути с пробелами, ошибки и отмена проверены\n'
