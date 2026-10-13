import Foundation

/// Bash scripts that stand in for `mo` in a real PTY. They print the same escape sequences Mole's menus use
/// (clear and home, then in-place line redraws), so the PTY session, the virtual screen, `MenuFrame` and the
/// driver run end to end without touching the real Mole.
enum ScriptedMole {
    /// `mo installer --dry-run` look-alike with a banner that says "No installer files will be removed",
    /// a spinner, then the menu. Keys: arrows, Space, Enter (confirm screen, then run), q / ESC.
    static let installer = #"""
    #!/bin/bash
    [ -n "$BURROW_SCRIPT_PIDFILE" ] && echo $$ > "$BURROW_SCRIPT_PIDFILE"
    names=("a.dmg" "b.zip" "c.pkg" "d.dmg" "e.dmg")
    sizes=(1 2 3 4 5)
    sel=(0 0 0 0 0)
    n=5; cur=0
    printf '\033[2J\033[H\033[0;33m→ DRY RUN MODE\033[0m, No installer files will be removed\r\n\r\n'
    printf '\033[?25l'
    for i in 1 2 3; do printf '\r\033[2K\033[1;34m⠖\033[0m Scanning for installers...'; sleep 0.05; done
    printf '\r\033[2K\r\n'
    draw() {
      local count=0 total=0 i
      for ((i=0;i<n;i++)); do if [ "${sel[i]}" = 1 ]; then count=$((count+1)); total=$((total+sizes[i])); fi; done
      printf '\033[H'
      printf '\r\033[2K\033[1;35mSelect Installers to Remove\033[0m \033[0;38;5;244m, %s.0MB, %s selected\033[0m\r\n' "$total" "$count"
      printf '\r\033[2K\r\n'
      for ((i=0;i<n;i++)); do
        local box="○"; [ "${sel[i]}" = 1 ] && box="●"
        if [ $i -eq $cur ]; then
          printf '\r\033[2K\033[0;36m➤ %s %-20s %s.0MB | Downloads \033[0m\r\n' "$box" "${names[i]}" "${sizes[i]}"
        else
          printf '\r\033[2K  %s %-20s %s.0MB | Downloads \r\n' "$box" "${names[i]}" "${sizes[i]}"
        fi
      done
      for ((i=0;i<8;i++)); do printf '\r\033[2K\r\n'; done
      printf '\r\033[2K\033[0;38;5;244m↑↓  |  Space Select  |  Enter Confirm  |  A All  |  I Invert  |  Q Quit\033[0m\r\n'
    }
    printf '\033[2J'
    draw
    while true; do
      IFS= read -rsn1 k
      case "$k" in
        q) printf '\033[?25h\r\n'; exit 0 ;;
        ' ') if [ "${sel[cur]}" = 1 ]; then sel[cur]=0; else sel[cur]=1; fi; draw ;;
        $'\033') IFS= read -rsn2 -t 1 rest
          case "$rest" in '[A') [ $cur -gt 0 ] && cur=$((cur-1)); draw ;; '[B') [ $cur -lt $((n-1)) ] && cur=$((cur+1)); draw ;; esac ;;
        '') break ;;
      esac
    done
    count=0; total=0
    printf '\033[2J\033[H'
    printf 'Files to be removed:\r\n'
    for ((i=0;i<n;i++)); do
      if [ "${sel[i]}" = 1 ]; then printf '  ✓ %s , %s.0MB\r\n' "${names[i]}" "${sizes[i]}"; count=$((count+1)); total=$((total+sizes[i])); fi
    done
    printf '\r\n➤ Delete %s installers, %s.0MB  Enter confirm, ESC cancel: ' "$count" "$total"
    IFS= read -rsn1 k
    if [ -n "$k" ]; then printf '\r\nCancelled\r\n'; exit 0; fi
    printf '\r\n======\r\nDry run complete - no changes made\r\nWould remove %s installers, free %s.00MB\r\n======\r\n' "$count" "$total"
    exit 0
    """#

    /// `mo purge --dry-run` look-alike. Like the real menu it redraws rows first, then (after `lag` seconds)
    /// the Project and Path lines, while the key hints stay on screen the whole time.
    static func purge(lag: String = "0.08") -> String {
        #"""
        #!/bin/bash
        [ -n "$BURROW_SCRIPT_PIDFILE" ] && echo $$ > "$BURROW_SCRIPT_PIDFILE"
        paths=("~/dev/a/node_modules" "~/dev/a/dist" "~/dev/b/node_modules" "~/dev/c/.venv")
        projs=("~/dev/a" "~/dev/a" "~/dev/b" "~/dev/c")
        arts=("node_modules" "dist" "node_modules" ".venv")
        sizes=(10 2 7 5)
        sel=(0 0 0 0)
        n=4; cur=0
        printf '\033[2J\033[H\033[0;33m→ DRY RUN MODE\033[0m, No project artifacts will be removed\r\n\r\n'
        draw() {
          local count=0 total=0 i
          for ((i=0;i<n;i++)); do if [ "${sel[i]}" = 1 ]; then count=$((count+1)); total=$((total+sizes[i])); fi; done
          printf '\033[H'
          printf '\r\033[2K\033[1;35mSelect Artifacts to Purge\033[0m\r\n'
          printf '\r\033[2K\033[0;38;5;244m%s.0MB, %s selected\033[0m\r\n' "$total" "$count"
          for ((i=0;i<n;i++)); do
            local box="○"; [ "${sel[i]}" = 1 ] && box="●"
            if [ $i -eq $cur ]; then
              printf '\r\033[2K\033[0;36m➤ %s ─ %-14s %s.0MB | %s | 13d\033[0m\r\n' "$box" "${projs[i]}" "${sizes[i]}" "${arts[i]}"
            else
              printf '\r\033[2K  %s ─ %-14s %s.0MB | %s | 13d\r\n' "$box" "${projs[i]}" "${sizes[i]}" "${arts[i]}"
            fi
          done
          printf '\r\033[2K\r\n'
          sleep LAG
          printf '\r\033[2K\033[0;38;5;244mProject: \033[0m%s · 1.0MB · 0/1 selected\r\n' "${projs[cur]}"
          printf '\r\033[2K\033[0;38;5;244mPath:\033[0m %s\r\n' "${paths[cur]}"
          printf '\r\033[2K\r\n'
          printf '\r\033[2K\033[0;38;5;244m↑↓ [] Projects / Find | Space Select | Enter Confirm | A All | I Invert | X Skip Project | Q Quit\033[0m\r\n'
        }
        printf '\033[2J'
        # First draw: the old footer is not on screen yet, as in the real menu's first frame.
        draw
        while true; do
          IFS= read -rsn1 k
          case "$k" in
            q) printf '\r\n'; exit 0 ;;
            ' ') if [ "${sel[cur]}" = 1 ]; then sel[cur]=0; else sel[cur]=1; fi; draw ;;
            $'\033') IFS= read -rsn2 -t 1 rest
              case "$rest" in '[A') [ $cur -gt 0 ] && cur=$((cur-1)); draw ;; '[B') [ $cur -lt $((n-1)) ] && cur=$((cur+1)); draw ;; esac ;;
            '') break ;;
          esac
        done
        count=0; total=0
        printf '\r\nSelected paths:\r\n'
        for ((i=0;i<n;i++)); do
          if [ "${sel[i]}" = 1 ]; then printf '  %s\r\n' "${paths[i]}"; count=$((count+1)); total=$((total+sizes[i])); fi
        done
        printf '➤ Remove %s artifacts, %s.0MB  Enter confirm, ESC cancel: ' "$count" "$total"
        IFS= read -rsn1 k
        if [ -n "$k" ]; then printf '\r\nCancelled\r\n'; exit 0; fi
        printf '\r\n'
        for ((i=0;i<n;i++)); do if [ "${sel[i]}" = 1 ]; then printf '✓ [DRY RUN] %s, %s.0MB\r\n' "${paths[i]}" "${sizes[i]}"; fi; done
        printf '======\r\nDry run complete - no changes made\r\nWould free approximately: %s.0MB | Items: %s | Free: 1.00GB\r\n======\r\n' "$total" "$count"
        exit 0
        """#.replacingOccurrences(of: "LAG", with: lag)
    }

    /// Prints a menu-less message and exits with `code`, like `mo installer` when there is nothing to do.
    static func exits(code: Int, message: String) -> String {
        "#!/bin/bash\nprintf '%s\\r\\n' '\(message)'\nexit \(code)\n"
    }

    /// `mo clean` look-alike: asks the sudo question with no trailing newline, only continues on Space.
    static let clean = #"""
    #!/bin/bash
    printf '\r\nClean Your Mac\r\n\r\n'
    printf '\033[0;35m➤\033[0m System caches need sudo. Enter continue, Space skip: '
    IFS= read -rsn1 key
    if [ "$key" != " " ]; then printf ' WRONG ANSWER [%s]\r\n' "$key"; exit 9; fi
    printf ' Skipped\r\n\r\n➤ Browsers\r\n  ✓ Chrome cache · 642.2MB\r\n'
    printf '\r\n======\r\nCleanup complete\r\nTracked cleanup: 1.20GB | Items cleaned: 17\r\nFree space: 781.48GB (+1.20GB)\r\n======\r\n'
    exit 0
    """#

    /// `mo clean` look-alike that asks for the admin password. Burrow must stop without typing anything.
    static let cleanPasswordPrompt = #"""
    #!/bin/bash
    printf '\r\nClean Your Mac\r\n\r\n'
    printf '➤ Enter your credentials:\r\nPassword:'
    IFS= read -rsn1 -t 30 key
    if [ -n "$key" ]; then printf '\r\nGOT KEY\r\n'; exit 9; fi
    exit 1
    """#

    /// `mo clean` look-alike that just sits there working.
    static let cleanHangs = #"""
    #!/bin/bash
    [ -n "$BURROW_SCRIPT_PIDFILE" ] && echo $$ > "$BURROW_SCRIPT_PIDFILE"
    printf '\r\nClean Your Mac\r\n\r\n'
    sleep 120
    """#

    /// `mo uninstall <name>` look-alike: matched list, "y", file list, Enter, removal and summary.
    static let uninstall = #"""
    #!/bin/bash
    [ -n "$BURROW_SCRIPT_PIDFILE" ] && echo $$ > "$BURROW_SCRIPT_PIDFILE"
    printf '◎ Matched 1 app(s):\r\n1. Flux  5.8MB  |  Last: Today\r\n\r\nProceed with uninstallation? [y/N] '
    IFS= read -r answer
    if [ "$answer" != "y" ]; then printf '\r\nAborted.\r\n'; exit 0; fi
    printf '\r\nFiles to be removed:\r\n\r\n◎ Flux , 5.9MB\r\n  ✓ /Applications/Flux.app , 5.8MB\r\n'
    for i in $(seq 1 70); do printf '  ✓ ~/Library/Caches/org.herf.Flux/file%s , %sKB\r\n' "$i" "$i"; done
    printf '\r\n➤ Remove 1 app, 5.9MB  Enter confirm, ESC cancel: '
    IFS= read -rsn1 k
    if [ -n "$k" ]; then printf '\r\nCancelled\r\n'; exit 0; fi
    printf '\r\nUninstalling Flux...\r\n\r\n======\r\nUninstall complete\r\nRemoved 1 app, freed 5.90MB: Flux\r\n======\r\n'
    exit 0
    """#
}
