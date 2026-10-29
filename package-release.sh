#!/bin/bash
# Build a distributable ClaudeDeck zip (universal app + CLI + installer) into dist/.
# Version comes from CFBundleShortVersionString in Info.plist.
set -e

APP_NAME="ClaudeDeck"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
STAGE="dist/${APP_NAME}-${VERSION}"
APP_DIR="${STAGE}/${APP_NAME}.app"
ZIP="dist/${APP_NAME}-${VERSION}-macos-universal.zip"

echo "Building universal release binaries (${VERSION})..."
swift build -c release --arch arm64 --arch x86_64 2>&1
# Ask SwiftPM where it put the products: the universal output directory differs
# between toolchains (.build/apple/... on older, .build/out/... on Xcode 27).
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)

echo "Assembling ${APP_DIR}..."
rm -rf "${STAGE}" "${ZIP}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "${BIN}/${APP_NAME}" "${APP_DIR}/Contents/MacOS/"
cp Info.plist "${APP_DIR}/Contents/"
cp Sources/App/Resources/AppIcon.icns "${APP_DIR}/Contents/Resources/"
cp Sources/App/Resources/ClaudeTerminalIcon.png "${APP_DIR}/Contents/Resources/"
cp Sources/App/Resources/ClaudeTerminalIcon@2x.png "${APP_DIR}/Contents/Resources/"
if [ -d "${BIN}/${APP_NAME}_${APP_NAME}.bundle" ]; then
    cp -R "${BIN}/${APP_NAME}_${APP_NAME}.bundle" "${APP_DIR}/Contents/Resources/"
fi
codesign -s - -f --deep "${APP_DIR}" >/dev/null

cp "${BIN}/claudedeck-cli" "${STAGE}/claudedeck"
codesign -s - -f "${STAGE}/claudedeck" >/dev/null

mkdir -p "${STAGE}/skills/claudedeck"
cp skills/claudedeck/SKILL.md "${STAGE}/skills/claudedeck/"

mkdir -p "${STAGE}/scripts"
cp scripts/*.sh "${STAGE}/scripts/"

cat > "${STAGE}/install.sh" <<'EOF'
#!/bin/bash
# Install ClaudeDeck.app to /Applications, the claudedeck CLI to ~/.claude/bin,
# the claudedeck skill to ~/.claude/skills, and its scripts to ~/.claude/scripts.
set -e
cd "$(dirname "$0")"
xattr -dr com.apple.quarantine ClaudeDeck.app claudedeck 2>/dev/null || true
rm -rf /Applications/ClaudeDeck.app
cp -R ClaudeDeck.app /Applications/
mkdir -p "${HOME}/.claude/bin"
# Remove first: overwriting an executed binary in place leaves a stale
# code-signature cache and the kernel SIGKILLs the next run on Apple Silicon.
rm -f "${HOME}/.claude/bin/claudedeck"
cp claudedeck "${HOME}/.claude/bin/claudedeck"
chmod +x "${HOME}/.claude/bin/claudedeck"
if [ -w /usr/local/bin ] || [ -w /usr/local ]; then
    ln -sf "${HOME}/.claude/bin/claudedeck" /usr/local/bin/claudedeck 2>/dev/null || true
fi
mkdir -p "${HOME}/.claude/skills/claudedeck"
cp skills/claudedeck/SKILL.md "${HOME}/.claude/skills/claudedeck/SKILL.md"
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
    "${HOME}/.claude/bin/claudedeck" statusline --install || echo "Status line not changed; run: claudedeck statusline --install"
fi
echo "Installed: /Applications/ClaudeDeck.app"
echo "CLI:       ${HOME}/.claude/bin/claudedeck"
echo "Skill:     ${HOME}/.claude/skills/claudedeck/SKILL.md"
echo "Scripts:   ${HOME}/.claude/scripts/launch-session.sh, self-console.sh"
EOF
chmod +x "${STAGE}/install.sh"

(cd dist && ditto -c -k --keepParent "${APP_NAME}-${VERSION}" "$(basename "${ZIP}")")
shasum -a 256 "${ZIP}" | tee "${ZIP}.sha256"
echo "Done: ${ZIP}"
