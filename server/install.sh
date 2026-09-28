#!/bin/bash
# Ставит crontab-записи для claude-usage (идемпотентно) и запускает сервис.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chmod +x "$DIR/watchdog.sh" "$DIR/usage_server.py"
( crontab -l 2>/dev/null | grep -v 'claude-usage/watchdog.sh'
  echo "@reboot sleep 20 && $DIR/watchdog.sh   # claude-usage/watchdog.sh"
  echo "*/5 * * * * $DIR/watchdog.sh   # claude-usage/watchdog.sh"
) | crontab -
"$DIR/watchdog.sh"
sleep 3
echo "--- crontab"; crontab -l
echo "--- listening"; ss -ltnp | grep 8766
echo "--- log"; tail -n 5 "$DIR/server.log"
