#!/bin/bash
set -euo pipefail
umask 077
export PATH="/opt/homebrew/bin:/usr/local/bin:/Applications/Docker.app/Contents/Resources/bin:/usr/bin:/bin"

DIR="${SUGARBAR_BACKUP_DIR:-$HOME/Documents/privat/sugarbar-backups}"
CONTAINER="${SUGARBAR_DB_CONTAINER:-sugarbar-db-1}"
KEEP="${SUGARBAR_BACKUP_KEEP:-14}"

mkdir -p "$DIR"
out="$DIR/sugarbar-$(date +%Y-%m-%d-%H%M%S).dump"
docker exec "$CONTAINER" pg_dump -U sugarbar -Fc sugarbar > "$out.partial"
mv "$out.partial" "$out"
echo "$(date '+%F %T') wrote $out ($(wc -c < "$out" | tr -d ' ') bytes)"

ls -1t "$DIR"/sugarbar-*.dump | tail -n +$((KEEP + 1)) | while read -r old; do rm -f "$old"; done
