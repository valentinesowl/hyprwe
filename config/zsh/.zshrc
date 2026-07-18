# ~/.config/zsh/.zshrc — HWE interactive zsh config.
# ZDOTDIR points here (set by ~/.zshenv, written by the installer), so all zsh
# dotfiles live under ~/.config/zsh — this whole dir is a symlink to the repo.
# Runtime state (history, compdump) is redirected OUT of the repo on purpose.

# --- History (kept in XDG state, not in the repo) -------------------------
HISTFILE="${XDG_STATE_HOME:-$HOME/.local/state}/zsh/history"
HISTSIZE=50000
SAVEHIST=50000
mkdir -p "${HISTFILE:h}"
setopt inc_append_history share_history hist_ignore_all_dups hist_reduce_blanks hist_verify

# --- Sane shell behaviour --------------------------------------------------
setopt auto_cd interactive_comments
bindkey -e                                   # emacs keybinds (Ctrl-A/E/R…)

# Up/Down: prefix history search — type `g`, press ↑ to cycle only `g…` lines.
autoload -Uz up-line-or-beginning-search down-line-or-beginning-search
zle -N up-line-or-beginning-search
zle -N down-line-or-beginning-search
[[ -n ${terminfo[kcuu1]} ]] && bindkey "${terminfo[kcuu1]}" up-line-or-beginning-search
[[ -n ${terminfo[kcdn1]} ]] && bindkey "${terminfo[kcdn1]}" down-line-or-beginning-search
bindkey '^[[A' up-line-or-beginning-search                  # ↑ (normal mode)
bindkey '^[[B' down-line-or-beginning-search                # ↓ (normal mode)
bindkey '^[OA' up-line-or-beginning-search                  # ↑ (application mode)
bindkey '^[OB' down-line-or-beginning-search                # ↓ (application mode)

# Word motion: zsh's emacs keymap only binds Alt+b/f, so Ctrl+←/→ arrive unbound
# and the terminal's escape tail leaks into the line. Bind what terminals send.
[[ -n ${terminfo[kLFT5]} ]] && bindkey "${terminfo[kLFT5]}" backward-word   # Ctrl+←
[[ -n ${terminfo[kRIT5]} ]] && bindkey "${terminfo[kRIT5]}" forward-word    # Ctrl+→
[[ -n ${terminfo[kLFT3]} ]] && bindkey "${terminfo[kLFT3]}" backward-word   # Alt+←
[[ -n ${terminfo[kRIT3]} ]] && bindkey "${terminfo[kRIT3]}" forward-word    # Alt+→
[[ -n ${terminfo[kDC5]}  ]] && bindkey "${terminfo[kDC5]}"  kill-word       # Ctrl+Del
bindkey '^[[1;5D' backward-word                             # fallbacks (no terminfo)
bindkey '^[[1;5C' forward-word
bindkey '^[[1;3D' backward-word
bindkey '^[[1;3C' forward-word
bindkey '^[[3;5~' kill-word
bindkey '^H'      backward-kill-word                        # Ctrl+Backspace

# --- Completion (compdump kept in XDG cache, not in the repo) --------------
autoload -Uz compinit
_zdump="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/zcompdump"
mkdir -p "${_zdump:h}"
compinit -d "$_zdump"
unset _zdump
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'   # case-insensitive
zstyle ':completion:*' list-colors ''

# --- Modern CLI aliases (tools from pkg/dev.lst) ---------------------------
if command -v eza >/dev/null; then
    alias ls='eza --icons=auto --group-directories-first'
    alias ll='eza -lah --icons=auto --group-directories-first'
    alias tree='eza --tree --icons=auto'
fi
command -v bat >/dev/null && alias cat='bat --plain --paging=never'
alias grep='grep --color=auto'
alias ..='cd ..'
alias ...='cd ../..'

# --- Plugins (Arch package paths) -----------------------------------------
# Order matters: syntax-highlighting must be sourced LAST.
_p=/usr/share/zsh/plugins
[[ -r $_p/zsh-autosuggestions/zsh-autosuggestions.zsh ]] \
    && source $_p/zsh-autosuggestions/zsh-autosuggestions.zsh
[[ -r $_p/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]] \
    && source $_p/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
unset _p

# --- Integrations ----------------------------------------------------------
command -v zoxide >/dev/null && eval "$(zoxide init zsh)"
[[ -r /usr/share/fzf/key-bindings.zsh ]] && source /usr/share/fzf/key-bindings.zsh
[[ -r /usr/share/fzf/completion.zsh   ]] && source /usr/share/fzf/completion.zsh

# --- Prompt: starship, single line (config: ~/.config/starship.toml) -------
command -v starship >/dev/null && eval "$(starship init zsh)"

PATH="$PATH:/home/$USER/.local/bin/"
