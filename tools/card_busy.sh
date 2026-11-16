#!/usr/bin/env bash
# card_busy.sh - is the rented card actually doing the work?
# Run it ~1 minute after starting any render, drawing or training run.
# Usage: bash card_busy.sh <user@host> <port> <key> <known_hosts> [seconds=30]
# Prints the card's average use and the processor's; exits 1 (with the reason) when the card is under 50% while the
# processor is busy, or when nothing is running at all: stop and fix before going on (card-only settings, batch size,
# data loading on the card, or the next step queued so the card never sits waiting).
set -u
H="$1"; P="$2"; K="$3"; KH="$4"; N="${5:-30}"
ssh -i "$K" -o UserKnownHostsFile="$KH" -o ConnectTimeout=20 -p "$P" "$H" "
  g=0; for i in \$(seq 1 $N); do u=\$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits | head -1); g=\$((g+u)); sleep 1; done
  g=\$((g/$N)); c=\$(top -bn1 | awk '/^%Cpu/{print int(100-\$8)}')
  echo \"card \$g% busy (average of $N s), processor \$c% busy\"
  if [ \$g -lt 50 ] && [ \$c -gt 30 ]; then echo 'SLOW: the processor is doing the card'\"'\"'s work (fix the settings: card only)'; exit 1; fi
  if [ \$g -lt 5 ]; then echo 'IDLE: the card is waiting (queue the next step or switch the card off)'; exit 1; fi
" 2>&1 | grep -v Warning
exit "${PIPESTATUS[0]}"
