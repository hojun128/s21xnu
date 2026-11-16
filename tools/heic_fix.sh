#!/bin/bash
# heic_fix.sh MOUNTPOINT : the S21 has no Apple HEVC decoder, HEIC images decode to all zeros (black wallpaper layers).
# Replace the wallpaper HEIC assets for this screen size (375w-812h) with PNG data under the same file names
# (ImageIO goes by content, not extension). Idempotent.
M=$1; n=0
find "$M/Library/Wallpaper" -iname "*.heic" -path "*375w-812h*" | while read f; do
  if file -b "$f" | grep -q HEIF; then
    sips -s format png "$f" --out /tmp/heicfix.png >/dev/null 2>&1 && cat /tmp/heicfix.png > "$f" && echo "converted ${f##*/} $(stat -f %z "$f")"
  fi
done
