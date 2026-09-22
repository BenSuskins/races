#!/usr/bin/env bash
#
# Install a launchd agent that captures the day's racing twice, so building a
# back-test corpus needs no discipline.
#
# Two runs, because one cannot do both jobs:
#
#   afternoon  the catalogue is populated and markets are live, so this is the
#              run that gets prices
#   late       racing has finished, so this is the run that gets results and
#              settled starting prices
#
# The free results endpoint is **today-only**. A day missed is a day gone, which
# is the whole argument for a scheduler rather than a reminder.
#
# Times are given in **London** — that is when racing happens — and converted to
# this machine's local time, because launchd schedules in local time. If you
# change timezone or the clocks go back, run this again.
#
#   ./scripts/install-capture-schedule.sh              # install
#   ./scripts/install-capture-schedule.sh --uninstall  # remove
#   ./scripts/install-capture-schedule.sh 15:00 22:30  # custom London times

set -euo pipefail

LABEL="com.bensuskins.races.capture"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/capture-fixtures.py"
LOG_DIR="$HOME/Library/Logs"

if [[ "${1:-}" == "--uninstall" ]]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Removed $LABEL"
  exit 0
fi

AFTERNOON_LONDON="${1:-15:00}"
LATE_LONDON="${2:-22:30}"

if [[ "$(uname)" != "Darwin" ]]; then
  echo "This installs a launchd agent, so it needs macOS." >&2
  echo "On Linux, put this in cron instead:" >&2
  echo "  0 15,22 * * * cd $REPO_ROOT && /usr/bin/python3 $SCRIPT" >&2
  exit 2
fi

if [[ ! -f "$SCRIPT" ]]; then
  echo "Can't find $SCRIPT" >&2
  exit 1
fi

# launchd schedules in local time; racing runs on London time. Convert, and show
# the working so a wrong answer is visible rather than silent.
read -r AFT_H AFT_M LATE_H LATE_M OFFSET_NOTE <<<"$(
  /usr/bin/python3 - "$AFTERNOON_LONDON" "$LATE_LONDON" <<'PY'
import datetime as dt, sys
from zoneinfo import ZoneInfo

london = ZoneInfo("Europe/London")
local = dt.datetime.now().astimezone().tzinfo
today = dt.date.today()

def to_local(hhmm):
    hour, minute = (int(part) for part in hhmm.split(":"))
    in_london = dt.datetime.combine(today, dt.time(hour, minute), tzinfo=london)
    here = in_london.astimezone(local)
    return here.hour, here.minute

a_h, a_m = to_local(sys.argv[1])
l_h, l_m = to_local(sys.argv[2])
shift = dt.datetime.now().astimezone().utcoffset() - dt.datetime.now(london).utcoffset()
hours = int(shift.total_seconds() // 3600)
note = "same-as-London" if hours == 0 else f"local-is-London{hours:+d}h"
print(a_h, a_m, l_h, l_m, note)
PY
)"

mkdir -p "$(dirname "$PLIST")" "$LOG_DIR"

cat >"$PLIST" <<PLIST_END
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>$SCRIPT</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$REPO_ROOT</string>
    <key>StartCalendarInterval</key>
    <array>
        <dict>
            <key>Hour</key><integer>$AFT_H</integer>
            <key>Minute</key><integer>$AFT_M</integer>
        </dict>
        <dict>
            <key>Hour</key><integer>$LATE_H</integer>
            <key>Minute</key><integer>$LATE_M</integer>
        </dict>
    </array>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/races-capture.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/races-capture.log</string>
    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
PLIST_END

plutil -lint "$PLIST" >/dev/null

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load "$PLIST"

printf 'Installed %s (%s)\n\n' "$LABEL" "$OFFSET_NOTE"
printf '  %-10s %s London  ->  %02d:%02d local   (catalogue + live prices)\n' \
  "afternoon" "$AFTERNOON_LONDON" "$AFT_H" "$AFT_M"
printf '  %-10s %s London  ->  %02d:%02d local   (results + settled SP)\n\n' \
  "late" "$LATE_LONDON" "$LATE_H" "$LATE_M"
echo "  corpus  $REPO_ROOT/capture/YYYY-MM-DD/"
echo "  log     $LOG_DIR/races-capture.log"
echo
echo "Credentials: put KEY=value lines in $REPO_ROOT/scripts/.capture-env (chmod 600)."
echo "Check it works now:  python3 $SCRIPT --dry-run"
echo "Re-run this script if you change timezone or the clocks change."
