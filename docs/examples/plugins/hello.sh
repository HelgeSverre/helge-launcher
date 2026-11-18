#!/bin/sh
# The smallest useful plugin: prints a fixed list, echoing the query back.
# Called as: hello.sh "<query>"
q="$1"
cat <<JSON
{"items": [
  {"title": "Hello, ${q:-world}", "subtitle": "Enter copies the greeting", "icon": "hand.wave",
   "actions": [{"title": "Copy", "copy": "Hello, ${q:-world}"}]},
  {"title": "Open the plugin docs", "icon": "book",
   "actions": [{"title": "Open", "open": "https://github.com/HelgeSverre/helge-launcher/blob/main/docs/plugins.md"}]}
]}
JSON
