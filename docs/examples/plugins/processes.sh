#!/bin/zsh
# Running processes, filtered by name.
#   Enter        quit (SIGTERM)
#   ⌘Enter       force kill (SIGKILL)
#   ⌘K           also: copy PID
# Only ps and awk, so it works without jq.

query="${1:l}"   # lowercased

# pid, %cpu, resident memory (KB), command name — no header row.
ps -axco pid=,pcpu=,rss=,comm= |
awk -v query="$query" '
  # Escape a string for a JSON string literal.
  function json(s) {
    gsub(/\\/, "\\\\", s)
    gsub(/"/, "\\\"", s)
    return "\"" s "\""
  }

  function action(title, kind, value) {
    return "{\"title\":" json(title) ",\"" kind "\":" json(value) "}"
  }

  BEGIN { printf "{\"items\":[" }

  {
    pid = $1
    cpu = $2
    mb = int($3 / 1024)
    name = $4
    for (i = 5; i <= NF; i++) name = name " " $i      # names can contain spaces

    if (query != "" && index(tolower(name), query) == 0) next
    if (count++ >= 40) next

    actions = action("Quit", "run", "kill " pid) "," \
              action("Force Kill", "run", "kill -9 " pid) "," \
              action("Copy PID", "copy", pid)

    printf "%s{\"title\":%s,\"subtitle\":%s,\"icon\":\"cpu\",\"actions\":[%s]}",
      (count > 1 ? "," : ""),
      json(name),
      json("PID " pid " · " cpu "% CPU · " mb " MB"),
      actions
  }

  END { print "]}" }
'
