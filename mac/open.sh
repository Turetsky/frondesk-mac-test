#!/bin/sh
# Frondesk.app opened by the person (Launchpad / Applications): continue the desk set-up in Terminal
# (it needs a real terminal for `claude setup-token`). ~/Frondesk/start.command is written by the .pkg.
if [ -x "$HOME/Frondesk/start.command" ]; then exec open -a Terminal "$HOME/Frondesk/start.command"; fi
exec open "https://kit.ytx.app/"
