#!/usr/bin/bash
# Installs SimpleDeckyTDP-MSI-Claw, the Decky TDP/power plugin tuned for the
# MSI Claw 8 EX AI+ (Panther Lake / Arc B390 "Xe3", model CG3EM).
#
# Usage:
#   curl -L https://raw.githubusercontent.com/JaelTanalepy/msi-claw-8-ex-ai-steamos-setup/main/install.sh | sh
#   VERSION=1.0.7+claw8ex.1 ./install.sh
#
# The plugin directory must match plugin.json's "name" (SimpleDeckyTDP-MSI-Claw)
# because Decky Loader derives the plugin folder from that field.

VERSION=${VERSION:-"LATEST"}
PLUGIN_NAME="SimpleDeckyTDP-MSI-Claw"
GITHUB_OWNER="JaelTanalepy"
GITHUB_REPO="msi-claw-8-ex-ai-steamos-setup"


if [ "$EUID" -eq 0 ]
  then echo "Please do not run as root"
  exit
fi


echo "removing previous install if it exists"

cd $HOME

# Remove only this fork's plugin. The upstream SimpleDeckyTDP and the original
# SimpleDeckyTDP-MSI-Claw fork are left alone on purpose: this script cannot know
# whether the user wants to keep them, and overwriting them would lose profiles.
sudo rm -rf "$HOME/homebrew/plugins/$PLUGIN_NAME"

echo "installing $PLUGIN_NAME plugin for TDP control"


FINAL_URL="https://api.github.com/repos/$GITHUB_OWNER/$GITHUB_REPO/releases/latest"
if [ "$VERSION" != "LATEST" ] ; then
  FINAL_URL="https://api.github.com/repos/$GITHUB_OWNER/$GITHUB_REPO/releases/tags/$VERSION"
fi

# download + install simple decky tdp
curl -L $(curl -s $FINAL_URL | grep "browser_download_url" | cut -d '"' -f 4) -o $HOME/simpledeckytdp-msi-claw.zip
sudo 7z x ./simpledeckytdp-msi-claw.zip  -o$HOME/homebrew/plugins

# install complete, remove build dir
rm  $HOME/simpledeckytdp-msi-claw.zip
sudo systemctl restart plugin_loader.service

echo "Installation complete"
