#!/bin/sh
# Art Frame - Start (scriptlet). Tap this in the Kindle library to start the
# daily art-frame loop.
#
# Per PLAN.md section 5 ("ArtFrame-Start.sh"): detaching with setsid before
# doing anything else is essential, because loop.sh will stop the very
# framework that launched this scriptlet. Keep this file minimal - all real
# logic lives in loop.sh. The launcher pipes this scriptlet's stdout to
# fbink, so the echo below is shown on the panel before the UI disappears;
# loop.sh's own output goes only to the log.
echo "Art Frame starting - the screen will change in about 15 s"
mkdir -p /mnt/us/artframe/logs
setsid sh /mnt/us/artframe/loop.sh >> /mnt/us/artframe/logs/artframe.log 2>&1 < /dev/null &
