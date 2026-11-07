#!/usr/bin/env bash
# Пробное восстановление: достаёт последнюю копию из облака во временную папку и проверяет, что её можно использовать.
# Рабочие файлы и базы не трогает. Код выхода 0 только если всё прошло.
# Обычно читает из облака 5% данных. С ключом --full читает всё: дольше, и хранилище может взять плату за скачивание.
set -uo pipefail

CONF_DIR="${SERVER_BACKUP_CONF:-/etc/server-backup}"
set -a; . "$CONF_DIR/config"; set +a
WORK_DIR="${WORK_DIR:-/var/backups/server-backup}"

T="$(mktemp -d /var/tmp/restore-check.XXXXXX)"
trap 'rm -rf "$T"' EXIT
fails=0
pass() { echo "OK    $1"; }
fail() { echo "СБОЙ  $1"; fails=$((fails + 1)); }

if [ "${1:-}" = "--full" ]; then read_arg=--read-data; else read_arg=--read-data-subset=5%; fi
restic check --quiet "$read_arg" > /dev/null 2>&1 && pass "хранилище в облаке целое ($read_arg)" || fail "проверка хранилища нашла ошибки: restic check $read_arg"

if restic restore latest --quiet --target "$T" --include "$WORK_DIR" > /dev/null; then
    pass "последняя копия скачана"
else
    fail "последнюю копию скачать не удалось"
fi

# Опись пишется при каждой копии. Если в облаке она старее рабочей, последняя копия до облака не дошла.
if cmp -s "$T$WORK_DIR/inventory.txt" "$WORK_DIR/inventory.txt"; then
    pass "в облаке самая свежая копия"
else
    fail "в облаке не самая свежая копия: опись отличается от рабочей"
fi

found=0
for f in "$T$WORK_DIR"/dumps/*; do
    [ -e "$f" ] || continue
    found=$((found + 1))
    n="$(basename "$f")"
    case "$n" in
        sqlite-*)
            [ "$(sqlite3 "$f" 'PRAGMA integrity_check;' 2>&1)" = "ok" ] && pass "дамп $n читается" || fail "дамп $n битый" ;;
        pgroles*)
            [ -s "$f" ] && pass "роли PostgreSQL $n на месте" || fail "файл ролей $n пустой" ;;
        pg-local-*)
            pg_restore --list "$f" > /dev/null 2>&1 && pass "дамп $n читается" || fail "дамп $n битый" ;;
        pg@*)
            c="${n#pg@}"; c="${c%%@*}"
            docker exec -i "$c" pg_restore --list < "$f" > /dev/null 2>&1 && pass "дамп $n читается" || fail "дамп $n битый (контейнер $c)" ;;
        mysql-*)
            gzip -t "$f" && zcat "$f" | tail -n 1 | grep -q "Dump completed" && pass "дамп $n читается" || fail "дамп $n битый" ;;
        *)
            echo "?     $n: не знаю, как проверить" ;;
    esac
done
# Каждый дамп с сервера должен быть и в копии.
for f in "$WORK_DIR"/dumps/*; do
    [ -e "$f" ] || continue
    [ -e "$T$WORK_DIR/dumps/$(basename "$f")" ] || fail "дампа $(basename "$f") нет в копии"
done
expected="$(grep -cE '^[[:space:]]*dump_' "$CONF_DIR/dumps.sh" || true)"
if [ "$found" -eq 0 ] && [ "$expected" -gt 0 ]; then
    fail "в настройках баз $expected, а дампов в копии нет"
elif [ "$found" -eq 0 ]; then
    echo "?     баз в настройках нет: это нормально, только если их нет и на сервере"
fi

A="$WORK_DIR/emergency/emergency.tar.zst.enc"
if [ "$(sha256sum "$A" | cut -d' ' -f1)" = "$(cat "$WORK_DIR/emergency/emergency.sha256")" ]; then
    pass "аварийный архив совпал с контрольной суммой"
else
    fail "аварийный архив не совпал с контрольной суммой"
fi
n="$(openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass "file:$RESTIC_PASSWORD_FILE" -in "$A" | zstd -dq | tar -t | wc -l)"
if [ "${PIPESTATUS[0]}" -eq 0 ] && [ "$n" -gt 0 ]; then
    pass "аварийный архив открывается паролем, файлов в нём: $n"
else
    fail "аварийный архив не открывается"
fi

echo
if [ "$fails" -eq 0 ]; then
    echo "Итог: копии можно использовать. Подъём на чистом сервере этой проверкой не проверяется."
else
    echo "Итог: сбоев $fails. Копиям пока доверять нельзя."
    exit 1
fi
