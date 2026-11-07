#!/usr/bin/env bash
# Компьютер сам забирает с сервера аварийный архив и хранит несколько версий. Для macOS и Linux.
# Сервер не знает, где лежит эта копия, и зайти сюда не может: её не сотрёт ни взломщик сервера, ни авария у хостинга.
# Запуск раз в сутки через cron (как завести — в SKILL.md).
set -euo pipefail

# --- Настройки ---
SERVER='root@АДРЕС_СЕРВЕРА'
SSH_KEY="$HOME/.ssh/КЛЮЧ_ОТ_СЕРВЕРА"
DEST="$HOME/server-backup/copies"
KEEP=7
REMOTE='/var/backups/server-backup/emergency'
# -----------------

LOG="$HOME/server-backup/pull.log"
SSH_OPTS=(-i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=30)
TMP="$DEST/emergency.tar.zst.enc.tmp"

sum() { if command -v sha256sum > /dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
log() { echo "$(date +%Y-%m-%dT%H:%M:%S) $1" >> "$LOG"; }
trap 'rm -f "$TMP"; log "ОШИБКА в строке $LINENO"' ERR

mkdir -p "$DEST"
remote_sum="$(ssh -n "${SSH_OPTS[@]}" "$SERVER" "cat $REMOTE/emergency.sha256")"
[[ "$remote_sum" =~ ^[0-9a-f]{64}$ ]]

last="$(ls -1 "$DEST"/emergency-*.tar.zst.enc 2>/dev/null | sort -r | head -n 1 || true)"
if [ -n "$last" ] && [ "$(sum "$last")" = "$remote_sum" ]; then
    log 'Нового архива нет'
else
    scp -q "${SSH_OPTS[@]}" "$SERVER:$REMOTE/emergency.tar.zst.enc" "$TMP"
    [ "$(sum "$TMP")" = "$remote_sum" ]
    mv "$TMP" "$DEST/emergency-$(date +%Y-%m-%d_%H%M).tar.zst.enc"
    scp -q "${SSH_OPTS[@]}" "$SERVER:$REMOTE/inventory.txt" "$DEST/inventory.txt"
    # Старые версии убираем только после того, как новая легла целиком.
    ls -1 "$DEST"/emergency-*.tar.zst.enc | sort -r | tail -n +$((KEEP + 1)) | while read -r old; do rm -f "$old"; done
    log 'OK: новый архив принят'
fi
# Отметка для сервера: по ней он заметит и напишет, если компьютер перестал забирать архив.
ssh -n "${SSH_OPTS[@]}" "$SERVER" "echo \$(date +%s) OK >> $REMOTE/pulled.log"
