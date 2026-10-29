#!/bin/bash
set -e

APP_NAME="ClaudeDeck"
APP_DIR="/Applications/${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"

echo "Building release binary..."
swift build -c release 2>&1

echo "Creating app bundle..."
rm -rf "${APP_DIR}"
mkdir -p "${MACOS}" "${RESOURCES}"

# Copy binary
cp ".build/release/${APP_NAME}" "${MACOS}/"

# Copy Info.plist
cp Info.plist "${CONTENTS}/"

# Copy icon
cp Sources/App/Resources/AppIcon.icns "${RESOURCES}/"

# Copy menu bar icon resources
cp Sources/App/Resources/ClaudeTerminalIcon.png "${RESOURCES}/"
cp Sources/App/Resources/ClaudeTerminalIcon@2x.png "${RESOURCES}/"

# Copy bundled resources (SPM resource bundle)
if [ -d ".build/release/${APP_NAME}_${APP_NAME}.bundle" ]; then
    cp -R ".build/release/${APP_NAME}_${APP_NAME}.bundle" "${RESOURCES}/"
fi

# Install the control CLI where skills and agents can find it.
CLI_DIR="${HOME}/.claude/bin"
mkdir -p "${CLI_DIR}"
# Remove first: overwriting an executed binary in place leaves a stale
# code-signature cache and the kernel SIGKILLs the next run on Apple Silicon.
rm -f "${CLI_DIR}/claudedeck"
cp ".build/release/claudedeck-cli" "${CLI_DIR}/claudedeck"
chmod +x "${CLI_DIR}/claudedeck"
codesign -s - -f "${CLI_DIR}/claudedeck" >/dev/null 2>&1 || true
if [ -w /usr/local/bin ] || [ -w /usr/local ]; then
    ln -sf "${CLI_DIR}/claudedeck" /usr/local/bin/claudedeck 2>/dev/null || true
fi

# Install the Claude Code skill that teaches sessions to use the CLI.
SKILL_DIR="${HOME}/.claude/skills/claudedeck"
mkdir -p "${SKILL_DIR}"
cp skills/claudedeck/SKILL.md "${SKILL_DIR}/SKILL.md"

# Install the scripts spawn, compact and clear run (launch-session.sh, self-console.sh)
# unless already there: a newer or customised copy is left alone. Lane hooks are optional;
# see README.
mkdir -p "${HOME}/.claude/scripts"
for f in launch-session.sh self-console.sh; do
    if [ ! -e "${HOME}/.claude/scripts/${f}" ]; then
        cp "scripts/${f}" "${HOME}/.claude/scripts/${f}"
        chmod +x "${HOME}/.claude/scripts/${f}"
    elif ! cmp -s "scripts/${f}" "${HOME}/.claude/scripts/${f}"; then
        echo "Kept your ~/.claude/scripts/${f} (differs from scripts/${f}; copy it over to update)."
    fi
done

# Point Claude Code's status line at ClaudeDeck so the usage bars get live numbers.
# An existing status line keeps its display (chained). Skip with CLAUDEDECK_NO_STATUSLINE=1.
if [ -z "${CLAUDEDECK_NO_STATUSLINE}" ]; then
    "${CLI_DIR}/claudedeck" statusline --install || echo "Status line not changed; run: claudedeck statusline --install"
fi

echo ""
echo "Installed: ${APP_DIR}"
echo "CLI:       ${CLI_DIR}/claudedeck"
echo "Skill:     ${SKILL_DIR}/SKILL.md"
echo "Done!"
