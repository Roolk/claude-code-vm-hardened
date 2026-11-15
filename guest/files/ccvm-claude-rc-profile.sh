# shellcheck shell=sh
# Managed by ccvm-harden. UNTESTED. On interactive login, warn if the
# Remote Control autostart (ccvm-claude-rc) is waiting for you to sign in.
if [ -n "${PS1-}" ] && [ -r "/run/user/$(id -u)/ccvm-claude-rc.status" ]; then
  case $(cut -d' ' -f1 "/run/user/$(id -u)/ccvm-claude-rc.status" 2>/dev/null) in
    not-signed-in)
      printf '\033[33m[ccvm] Claude Remote Control is NOT running: Claude is not signed in.\033[0m\n'
      printf '       Run  claude  and sign in (or: claude auth login). It starts within a minute.\n' ;;
    exited)
      printf '\033[33m[ccvm] Claude Remote Control exited and is restarting. Look: tmux attach -t claude-rc\033[0m\n' ;;
  esac
fi
