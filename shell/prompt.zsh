#!/usr/bin/env zsh
# jarvis-standards / shell / prompt.zsh
#
# Shared JARVIS shell prompt — unified visual identity across all nodes.
# Sourced from each node's ~/.zshrc. Node identity from $JARVIS_NODE.
#
# Usage in ~/.zshrc:
#   export JARVIS_NODE=sandbox          # air | brain | gateway | endpoint | sandbox
#   source ~/jarvis-standards/shell/prompt.zsh
#
# Design:
#   <emoji> <NODE> <node>@<node> <short-path> (<branch>*) <$>
#   - Emoji + color = at-a-glance node identity
#   - <node>@<node> format mirrors across nodes (symmetric visual parse)
#   - Short path (last 2 segments) reduces visual noise
#   - Git branch shown only in repos; trailing * = dirty tree
#   - $ turns red on last non-zero exit (failure cue)
#   - (venv) prefix when $VIRTUAL_ENV set

[[ -z "$JARVIS_NODE" ]] && return 0

case "$JARVIS_NODE" in
  air)      _jprompt_emoji="💻"; _jprompt_label="AIR";      _jprompt_color="51"  ;;
  brain)    _jprompt_emoji="🟢"; _jprompt_label="BRAIN";    _jprompt_color="46"  ;;
  gateway)  _jprompt_emoji="🟡"; _jprompt_label="GATEWAY";  _jprompt_color="220" ;;
  endpoint) _jprompt_emoji="🔵"; _jprompt_label="ENDPOINT"; _jprompt_color="33"  ;;
  sandbox)  _jprompt_emoji="🔴"; _jprompt_label="SANDBOX";  _jprompt_color="196" ;;
  *)
    _jprompt_emoji="❓"; _jprompt_label="${JARVIS_NODE:u}"; _jprompt_color="245"
    ;;
esac

setopt PROMPT_SUBST

_jprompt_git_branch() {
  local branch
  branch=$(git symbolic-ref --short HEAD 2>/dev/null) || return
  local dirty=""
  git diff-index --quiet HEAD -- 2>/dev/null || dirty="*"
  print -n " (%F{245}${branch}${dirty}%f)"
}

_jprompt_short_path() {
  local p="${PWD/#$HOME/~}"
  local -a segs
  segs=("${(@s:/:)p}")
  if (( ${#segs} > 2 )); then
    print -n "${segs[-2]}/${segs[-1]}"
  else
    print -n "$p"
  fi
}

_jprompt_venv() {
  [[ -n "$VIRTUAL_ENV" ]] && print -n "%F{245}($(basename $VIRTUAL_ENV))%f "
}

_jprompt_char() {
  print -n '%(?.%f$.%F{196}$%f)'
}

PROMPT='$(_jprompt_venv)%F{'"${_jprompt_color}"'}'"${_jprompt_emoji}"' '"${_jprompt_label}"'%f %F{'"${_jprompt_color}"'}'"${JARVIS_NODE}@${JARVIS_NODE}"'%f %F{250}$(_jprompt_short_path)%f$(_jprompt_git_branch) $(_jprompt_char) '

export JARVIS_PROMPT_LOADED=1
