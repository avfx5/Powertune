#!/bin/sh
# Run without sudo. SearXNG itself is in the AUR, not pacman's repos: yay -S searxng-git
set -e
cd "$(dirname "$0")/sxfire"
sudo pacman -S --needed curl jq xdg-utils firefox
mkdir -p ~/.local/bin ~/.local/share/applications ~/.local/share/sxfire/profile/chrome
cp sxfire sxfire-open ~/.local/bin/
chmod +x ~/.local/bin/sxfire ~/.local/bin/sxfire-open
cp firesx/profile/user.js ~/.local/share/sxfire/profile/
cp firesx/profile/chrome/userChrome.css ~/.local/share/sxfire/profile/chrome/
cat > ~/.local/share/applications/sxfire-open.desktop <<EOF
[Desktop Entry]
Type=Application
Name=sxfire link opener
Exec=$HOME/.local/bin/sxfire-open %u
MimeType=x-scheme-handler/sxfire;
NoDisplay=true
EOF
xdg-mime default sxfire-open.desktop x-scheme-handler/sxfire
echo "Done. Try: sxfire hello world"
