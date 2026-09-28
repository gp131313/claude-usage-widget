#!/bin/bash
# Запускает usage_server.py, если он не работает. Вызывается из crontab (@reboot и раз в 5 мин).
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$DIR/server.log"
PIDF="$DIR/server.pid"
if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
  exit 0
fi
# лог не растёт бесконечно
if [ -f "$LOG" ] && [ "$(stat -c %s "$LOG")" -gt 1048576 ]; then
  tail -n 500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi
cd "$DIR" || exit 1
nohup /usr/bin/python3 "$DIR/usage_server.py" >> "$LOG" 2>&1 &
echo $! > "$PIDF"
echo "$(date '+%F %T') watchdog: started pid $!" >> "$LOG"
