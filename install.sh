#!/usr/bin/env bash
set -euo pipefail

TOOLS_TARGET=""

usage() {
  cat <<'EOF'
Usage: ./install.sh [--tools-target <dir>]

Installs the chat-mode Codex Skill and optionally copies helper tools into a host project.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tools-target)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "error: --tools-target requires a directory" >&2
        exit 1
      fi
      TOOLS_TARGET="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_SOURCE="$SCRIPT_DIR/skills/chat-mode"
TOOLS_SOURCE="$SCRIPT_DIR/tools"

if [[ ! -d "$SKILL_SOURCE" ]]; then
  echo "error: missing skill source: $SKILL_SOURCE" >&2
  exit 1
fi

detect_os() {
  case "$(uname -s)" in
    Darwin) echo "macos" ;;
    Linux) echo "linux" ;;
    *)
      echo "unsupported"
      ;;
  esac
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

is_debian_like() {
  [[ -f /etc/os-release ]] && grep -Eiq '(^ID=|^ID_LIKE=).*(debian|ubuntu)' /etc/os-release
}

install_with_apt() {
  local package_name="$1"
  if ! has_cmd sudo; then
    echo "error: sudo is required to install $package_name with apt" >&2
    exit 1
  fi
  sudo apt-get update
  sudo apt-get install -y "$package_name"
}

install_git() {
  local os="$1"
  if has_cmd git; then
    echo "[ok] git found: $(command -v git)"
    return
  fi

  echo "[install] git is missing"
  case "$os" in
    macos)
      if ! has_cmd brew; then
        echo "error: Homebrew is required to auto-install git on macOS: https://brew.sh/" >&2
        exit 1
      fi
      brew install git
      ;;
    linux)
      if is_debian_like; then
        install_with_apt git
      else
        echo "error: install git manually for this Linux distribution, then rerun install.sh" >&2
        exit 1
      fi
      ;;
    *)
      echo "error: unsupported OS for git auto-install" >&2
      exit 1
      ;;
  esac
}

install_pwsh() {
  local os="$1"
  if has_cmd pwsh; then
    echo "[ok] pwsh found: $(command -v pwsh)"
    return
  fi

  echo "[install] pwsh is missing"
  case "$os" in
    macos)
      if ! has_cmd brew; then
        echo "error: Homebrew is required to auto-install PowerShell on macOS: https://brew.sh/" >&2
        exit 1
      fi
      brew install --cask powershell
      ;;
    linux)
      if is_debian_like; then
        if ! has_cmd sudo; then
          echo "error: sudo is required to install PowerShell with snap" >&2
          exit 1
        fi
        if ! has_cmd snap; then
          echo "error: snap is required for automatic PowerShell install on Ubuntu/Debian." >&2
          echo "Install manually: https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-linux" >&2
          exit 1
        fi
        sudo snap install powershell --classic
      else
        echo "error: automatic PowerShell install is only supported on Ubuntu/Debian and macOS." >&2
        echo "Install manually: https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-linux" >&2
        exit 1
      fi
      ;;
    *)
      echo "error: unsupported OS for PowerShell auto-install" >&2
      exit 1
      ;;
  esac
}

check_optional_cli() {
  local name="$1"
  local url="$2"
  if has_cmd "$name"; then
    echo "[ok] $name found: $(command -v "$name")"
  else
    echo "[warn] $name not found. Install and authenticate it when you want full two-agent automation."
    echo "       $url"
  fi
}

copy_dir_replace() {
  local source_dir="$1"
  local target_dir="$2"
  mkdir -p "$(dirname "$target_dir")"
  rm -rf "$target_dir"
  cp -R "$source_dir" "$target_dir"
}

OS_NAME="$(detect_os)"
if [[ "$OS_NAME" == "unsupported" ]]; then
  echo "error: unsupported OS: $(uname -s)" >&2
  exit 1
fi

echo "[info] detected OS: $OS_NAME"

install_git "$OS_NAME"
install_pwsh "$OS_NAME"
check_optional_cli "codex" "https://github.com/openai/codex"
check_optional_cli "claude" "https://docs.anthropic.com/en/docs/claude-code"

if [[ -n "${CODEX_HOME:-}" ]]; then
  SKILLS_ROOT="$CODEX_HOME/skills"
else
  SKILLS_ROOT="$HOME/.codex/skills"
fi

SKILL_TARGET="$SKILLS_ROOT/chat-mode"
echo "[install] copying skill to $SKILL_TARGET"
copy_dir_replace "$SKILL_SOURCE" "$SKILL_TARGET"

if [[ -n "$TOOLS_TARGET" ]]; then
  if [[ ! -d "$TOOLS_SOURCE" ]]; then
    echo "error: missing tools source: $TOOLS_SOURCE" >&2
    exit 1
  fi
  mkdir -p "$TOOLS_TARGET"
  echo "[install] copying tools to $TOOLS_TARGET"
  cp -R "$TOOLS_SOURCE/." "$TOOLS_TARGET/"
fi

echo
echo "chat-mode-skill installed successfully."
echo "Skill: $SKILL_TARGET"
if [[ -n "$TOOLS_TARGET" ]]; then
  echo "Tools: $TOOLS_TARGET"
else
  echo "Tools: not copied. Pass --tools-target <dir> to copy helper scripts into a host project."
fi
