# Oh My Zsh setup
export ZSH="$HOME/.oh-my-zsh"

# Plugins for fish-like autosuggestions, syntax highlighting, and better completion
plugins=(
  git
  zsh-autosuggestions
  zsh-syntax-highlighting
  zsh-completions
)

source $ZSH/oh-my-zsh.sh

# Lines configured by zsh-newuser-install
HISTFILE=~/.histfile
HISTSIZE=1000
SAVEHIST=1000
# End of lines configured by zsh-newuser-install

# The following lines were added by compinstall
zstyle :compinstall filename '/home/alex/.zshrc'

autoload -Uz compinit
compinit
# End of lines added by compinstall

export XDG_DATA_DIRS="$XDG_DATA_DIRS:/var/lib/flatpak/exports/share:/home/alex/.local/share/flatpak/exports/share"

[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh

# Run fastfetch on interactive shell start
if [[ -o interactive ]] && command -v fastfetch >/dev/null 2>&1; then
  fastfetch
fi

export EDITOR="nvim"
export VISUAL="nvim"

autoload -Uz colors && colors

PROMPT='%F{green}%n@%m%f:%~$ '

alias update-grub='sudo grub-mkconfig -o /boot/grub/grub.cfg'
alias update-grub2='sudo grub2-mkconfig -o /boot/grub2/grub.cfg'

unset GPG_AGENT_INFO
export GPG_TTY=$(tty)

# >>> flatpak scope picker >>>
# Wraps `flatpak install` so it asks whether to install for just you
# (user, no sudo) or for everyone on the machine (system, needs sudo),
# similar to the prompt openSUSE Tumbleweed shows.
flatpak() {
    if [[ "$1" == "install" ]]; then
        shift
        local scope_choice
        echo "Flatpak install scope:"
        echo "  1) User   - only your account, no sudo required"
        echo "  2) System - all users on this machine, requires sudo"
        printf '%s' "Select [1/2] (default 1): "
        read -r scope_choice
        case "${scope_choice}" in
            2)
                sudo command flatpak install --system "$@"
                ;;
            *)
                command flatpak install --user "$@"
                ;;
        esac
    else
        command flatpak "$@"
    fi
}
# <<< flatpak scope picker <
