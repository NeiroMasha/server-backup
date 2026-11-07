#!/usr/bin/env bash
# Ночная копия сервера: дампы баз, опись сервера, аварийный архив для компьютера, зашифрованная копия в облако.
# Настройки: /etc/server-backup/config и /etc/server-backup/dumps.sh (образцы в assets/).
# Проверка уведомлений без копии: server-backup --test-notify
set -Eeuo pipefail

CONF_DIR="${SERVER_BACKUP_CONF:-/etc/server-backup}"
set -a; . "$CONF_DIR/config"; set +a

WORK_DIR="${WORK_DIR:-/var/backups/server-backup}"
DUMPS="$WORK_DIR/dumps"
OUT="$WORK_DIR/emergency"
HOST_NAME="$(hostname)"

send_telegram() {
    # Токен передаём через stdin, а не в аргументах: иначе он виден в списке процессов.
    curl -fsS -m 20 --retry 3 -o /dev/null -K - --data-urlencode "chat_id=${TG_CHAT:-}" \
        --data-urlencode "text=$HOST_NAME: $1" <<<"url = \"https://api.telegram.org/bot$TG_TOKEN/sendMessage\""
}
send_watchdog() {
    curl -fsS -m 10 --retry 3 -o /dev/null "$HC_URL$1"
}
notify() {
    [ -n "${TG_TOKEN:-}" ] || return 0
    send_telegram "$1" || true
}
ping_watchdog() {
    [ -n "${HC_URL:-}" ] || return 0
    send_watchdog "$1" || true
}
die() {
    trap - ERR
    echo "ОШИБКА: $1" >&2
    notify "❌ Копия не сделана: $1"
    ping_watchdog /fail
    exit 1
}
STEP="подготовка"
trap 'die "сломался шаг «$STEP» (строка $LINENO)"' ERR

if [ "${1:-}" = "--test-notify" ]; then
    if [ -z "${TG_TOKEN:-}" ] && [ -z "${HC_URL:-}" ]; then
        echo "Уведомления не настроены: о сбое копии никто не узнает."
        exit 1
    fi
    if ! command -v curl > /dev/null; then
        echo "Нет программы curl: уведомления не уйдут."
        exit 1
    fi
    rc=0
    if [ -n "${TG_TOKEN:-}" ]; then
        if send_telegram "🔔 Проверка уведомлений: если ты это читаешь, сообщения о копиях дойдут."; then
            echo "Telegram: отправлено, проверь, что сообщение пришло."
        else
            echo "Telegram: не отправлено, проверь токен и chat id."; rc=1
        fi
    fi
    if [ -n "${HC_URL:-}" ]; then
        if send_watchdog ""; then echo "Сторож: отметка принята."; else echo "Сторож: не отвечает, проверь адрес."; rc=1; fi
    fi
    exit "$rc"
fi

if [ -n "${TG_TOKEN:-}${HC_URL:-}" ] && ! command -v curl > /dev/null; then
    die "нет программы curl, уведомления не работают"
fi

mkdir -p "$DUMPS" "$OUT"
chmod 700 "$WORK_DIR"
exec 9>"$WORK_DIR/.lock"
flock -n 9 || die "прошлая копия ещё идёт"
ping_watchdog /start

free_gb="$(df -BG --output=avail "$WORK_DIR" | tail -1 | tr -dc 0-9)"
[ "$free_gb" -ge "${MIN_FREE_GB:-3}" ] || die "мало места на диске: свободно ${free_gb} ГБ"
rm -f "$DUMPS"/*.tmp

# Папку, которой нет, не передаём дальше: tar на ней падает. Но молчать о ней нельзя, вдруг данные переехали.
warn=""
paths=()
for p in "${BACKUP_PATHS[@]}"; do
    if [ -e "$p" ]; then paths+=("$p"); else warn="$warn папки $p нет на сервере."; fi
done

# --- Дампы баз. Каждая функция останавливает копию, если дамп пустой или не читается:
# лучше честная тревога ночью, чем старый дамп в копии и сообщение об успехе.

dump_sqlite() { # путь_к_базе имя
    STEP="дамп базы $2"
    local f="$DUMPS/sqlite-$2.sqlite"
    sqlite3 "$1" ".backup '$f.tmp'"
    test -s "$f.tmp"
    [ "$(sqlite3 "$f.tmp" 'PRAGMA integrity_check;')" = "ok" ]
    mv "$f.tmp" "$f"
}
dump_postgres_docker() { # контейнер пользователь база
    STEP="дамп базы $3"
    local f="$DUMPS/pg@$1@$3.dump"
    docker exec "$1" pg_dump -U "$2" -Fc "$3" > "$f.tmp"
    test -s "$f.tmp"
    docker exec -i "$1" pg_restore --list < "$f.tmp" > /dev/null
    mv "$f.tmp" "$f"
    # Роли и их пароли в дамп базы не входят, а без них на новом сервере база не поднимется.
    local r="$DUMPS/pgroles@$1.sql"
    if docker exec "$1" pg_dumpall -U "$2" --globals-only > "$r.tmp" && test -s "$r.tmp"; then
        mv "$r.tmp" "$r"
    else
        rm -f "$r.tmp"; warn="$warn роли PostgreSQL в контейнере $1 не сохранены: пользователю $2 не хватает прав."
    fi
}
dump_postgres_local() { # база (системный пользователь postgres)
    STEP="дамп базы $1"
    local f="$DUMPS/pg-local-$1.dump"
    runuser -u postgres -- pg_dump -Fc "$1" > "$f.tmp"
    test -s "$f.tmp"
    pg_restore --list "$f.tmp" > /dev/null
    mv "$f.tmp" "$f"
    # Роли и их пароли в дамп базы не входят, а без них на новом сервере база не поднимется.
    runuser -u postgres -- pg_dumpall --globals-only > "$DUMPS/pgroles-local.sql.tmp"
    test -s "$DUMPS/pgroles-local.sql.tmp"
    mv "$DUMPS/pgroles-local.sql.tmp" "$DUMPS/pgroles-local.sql"
}
dump_mysql_docker() { # контейнер база (пароль берётся из MYSQL_ROOT_PASSWORD или MARIADB_ROOT_PASSWORD внутри контейнера)
    STEP="дамп базы $2"
    local f="$DUMPS/mysql-$1-$2.sql.gz"
    docker exec "$1" sh -c 'p="${MARIADB_ROOT_PASSWORD:-$MYSQL_ROOT_PASSWORD}"; t=$(command -v mariadb-dump || command -v mysqldump); MYSQL_PWD="$p" exec "$t" -uroot --single-transaction --routines "$0"' "$2" \
        | gzip > "$f.tmp"
    gzip -t "$f.tmp"
    zcat "$f.tmp" | tail -n 1 | grep -q "Dump completed"
    mv "$f.tmp" "$f"
}

. "$CONF_DIR/dumps.sh"

STEP="опись сервера"
# --- Опись: что стояло на сервере. Без неё после потери сервера всё это пришлось бы вспоминать.
section() {
    local title="$1"; shift
    printf '\n===== %s =====\n' "$title"
    "$@" 2>&1 || true
}
# Только расписание и имя программы: в аргументах команд бывают токены, а опись лежит на компьютере открытым файлом.
cron_safe() {
    crontab -l | awk '/^[[:space:]]*(#|$)/ { next } /^[A-Za-z_]+[[:space:]]*=/ { next }
        /^@/ { c = $2; sub(/=.*/, "=…", c); print $1, c; next }
        { c = $6; sub(/=.*/, "=…", c); print $1, $2, $3, $4, $5, c }'
}
{
    echo "Опись сервера $HOST_NAME, $(date -Is)"
    section "Система" cat /etc/os-release
    section "Пакеты" sh -c 'dpkg-query -W -f="\${Package} \${Version}\n" 2>/dev/null || rpm -qa'
    section "Запущенные службы" systemctl list-units --type=service --state=running --no-pager --plain
    section "Таймеры" systemctl list-timers --all --no-pager
    section "Контейнеры" docker ps -a --format '{{.Names}}  {{.Image}}  {{.Ports}}'
    section "Расписание root" cron_safe
    section "Порты" ss -tlnup
    section "Файрвол ufw" ufw status verbose
    section "Файрвол iptables" iptables-save
    section "Сертификаты" sh -c 'ls -1 /etc/letsencrypt/live'
} > "$WORK_DIR/inventory.txt"

STEP="аварийный архив"
# --- Аварийный архив для компьютера: без тяжёлых файлов. Его забирает сам компьютер, сервер туда попасть не может.
# Собираем до отправки в облако: если облако сегодня недоступно, у компьютера всё равно будет свежий архив.
tar_excl=(--exclude="$OUT" --exclude="$WORK_DIR/.lock" --exclude='*.tmp')
for e in "${BACKUP_EXCLUDES[@]:-}" "${EMERGENCY_EXCLUDES[@]:-}"; do
    [ -n "$e" ] && tar_excl+=(--exclude="$e")
done
set +e
tar --one-file-system --warning=no-file-changed "${tar_excl[@]}" -cf - "${paths[@]}" "$WORK_DIR" 2>/dev/null \
    | zstd -q -T0 \
    | openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -pass "file:$RESTIC_PASSWORD_FILE" -out "$OUT/emergency.tar.zst.enc.tmp"
st=("${PIPESTATUS[@]}")
set -e
# Код 1 у tar значит «файл менялся во время чтения», для работающего сервера это норма.
if [ "${st[0]}" -gt 1 ] || [ "${st[1]}" -ne 0 ] || [ "${st[2]}" -ne 0 ]; then
    die "аварийный архив не собран (tar ${st[0]}, zstd ${st[1]}, openssl ${st[2]})"
fi
test -s "$OUT/emergency.tar.zst.enc.tmp"
mv "$OUT/emergency.tar.zst.enc.tmp" "$OUT/emergency.tar.zst.enc"
sha256sum "$OUT/emergency.tar.zst.enc" | cut -d' ' -f1 > "$OUT/emergency.sha256"
cp "$WORK_DIR/inventory.txt" "$OUT/inventory.txt"
emergency_size="$(du -h "$OUT/emergency.tar.zst.enc" | cut -f1)"

STEP="копия в облако"
# --- Зашифрованная копия в облако.
restic_excl=(--exclude="$OUT" --exclude="$WORK_DIR/.lock" --exclude='*.tmp')
for e in "${BACKUP_EXCLUDES[@]:-}"; do
    [ -n "$e" ] && restic_excl+=(--exclude="$e")
done
rc=0
restic backup --quiet --tag nightly --one-file-system "${restic_excl[@]}" "${paths[@]}" "$WORK_DIR" || rc=$?
# Код 3: копия сделана, но часть файлов не прочиталась.
if [ "$rc" -eq 3 ]; then
    warn="$warn часть файлов не прочиталась, смотри journalctl -u server-backup."
elif [ "$rc" -ne 0 ]; then
    die "облако не приняло копию (restic, код $rc)"
fi
restic forget --quiet --keep-daily "${KEEP_DAILY:-7}" --keep-weekly "${KEEP_WEEKLY:-4}" --keep-monthly "${KEEP_MONTHLY:-6}" --prune
STEP="проверка копии в облаке"
# Раз в неделю читаем часть копии из облака: так находятся испорченные файлы.
if [ "$(date +%u)" = "7" ]; then
    restic check --quiet --read-data-subset=5%
fi

# --- Забирал ли компьютер архив. Его молчание само по себе проблема.
if [ "${PULL_EXPECTED:-no}" = "yes" ]; then
    mark="$OUT/pulled.log"
    if [ ! -s "$mark" ]; then
        warn="$warn компьютер ещё ни разу не забрал аварийный архив."
    elif [ $(( $(date +%s) - $(tail -n 1 "$mark" | cut -d' ' -f1) )) -gt 259200 ]; then
        warn="$warn компьютер не забирал аварийный архив больше 3 дней."
    fi
fi

snapshots="$(restic snapshots --json | grep -o '"short_id"' | wc -l)"
if [ -n "$warn" ]; then
    notify "⚠️ Копия сделана, но:$warn Снимков в облаке: $snapshots, аварийный архив $emergency_size."
else
    notify "✅ Копия сделана. Снимков в облаке: $snapshots, аварийный архив $emergency_size."
fi
ping_watchdog ""
echo "Готово. Снимков: $snapshots, аварийный архив: $emergency_size.$warn"
