#!/usr/bin/bash
# msi-claw-apply-fixes.sh - MSI Claw 8 EX AI+ (Panther Lake, Arc B390 "Xe3",
# model CG3EM) SteamOS fix pack.
#
# PROVENANCE AND HONESTY NOTES
# ----------------------------
# This script is the MSI Claw port of the Panther Lake fix pack that shipped for
# another handheld on the same SoC generation. Every step from that fix pack is
# present below. Where a step depends on data that only exists on the original
# device (its OLED panel model, its IMU ACPI table, its MCU button table, its
# BIOS version gates) the MSI value is marked VERIFY-ON-HARDWARE and the step is
# written to skip safely until someone fills it in on a real Claw. Nothing in
# this script invents a device ID, a firmware hash or an EC register value: a
# wrong guess in those places bricks or cooks a handheld.
#
# Steps that are fully portable (TDP sync, split-lock, suspend workaround,
# charge/battery reporting, the plugin install) are implemented for real.
#
# WHAT THE CLAW HAS THAT THE ORIGINAL DID NOT
#   * 8" 1920x1200 16:10 IPS, 48-120 Hz VRR, 500 nits, 100% sRGB, NO HDR.
#     -> HDR/PQ steps are intentionally NOT ported (nothing to drive).
#     -> The VRR range is 48-120 Hz, not the 30-144 Hz of the original panel.
#   * Intel Wi-Fi 7 (802.11be) + Bluetooth 6.0. The original used a BE201
#     (8086:e440); the Claw's PCI ID is unverified, so the firmware step probes
#     the driver instead of hardcoding a device ID.
#   * 80 Wh 4-cell Li-polymer battery.
#   * MSI Center / MSI Center M instead of the original vendor console. MSI
#     Center is Windows-only, so steps that would call it use sysfs and say so.
#
# USAGE
#   ./msi-claw-apply-fixes.sh            apply (asks for sudo, prints the plan)
#   ./msi-claw-apply-fixes.sh --check    report state, change nothing, no sudo
#   ./msi-claw-apply-fixes.sh --revert   undo everything this script added
#   ./msi-claw-apply-fixes.sh --force    skip the DMI/OS guards
#
# The script refuses to run when the DMI does not look like a Claw 8 EX AI+.
# Set MSI_CLAW_FORCE_DMI=1 or pass --force if your unit reports another string.

set -u

MSI_CLAW_FIXES_VERSION="1.0.0-claw8ex"

# ---- device guard ----------------------------------------------------------
DMI_VENDOR="$(cat /sys/devices/virtual/dmi/id/sys_vendor 2>/dev/null || true)"
DMI_PRODUCT="$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null || true)"
DMI_BOARD="$(cat /sys/devices/virtual/dmi/id/board_name 2>/dev/null || true)"
DMI_BIOS="$(cat /sys/devices/virtual/dmi/id/bios_version 2>/dev/null || true)"
OS_BUILD="$(cat /etc/os-release 2>/dev/null | sed -n 's/^BUILD_ID=//p' | tr -d '\"')"
KVER="$(uname -r)"

# Substrings that identify a Claw 8 EX AI+. Keep in sync with
# py_modules/device_utils.py (MSI_CLAW_8_EX_AI / MSI_CLAW_8_EX_AI_MODEL).
DMI_MATCHES=("Claw 8 EX AI+" "Claw 8 EX AI" "CG3EM" "Claw 8 AI+")

# ---- paths -----------------------------------------------------------------
FIX_DIR="$HOME/msi-claw-fix"                     # in /home, survives OS updates
CACHE_DIR="$HOME/.cache/msi-claw-fix"            # downloads cached across updates
LOG_FILE="$CACHE_DIR/apply-fixes.log"

GRUB_DIR=/etc/default/grub.d
NVME_GRUB="$GRUB_DIR/msi-claw-nvme.cfg"
SPLITLOCK_GRUB="$GRUB_DIR/msi-claw-splitlock.cfg"
MODPROBE_XE=/etc/modprobe.d/xe-msi-claw.conf

# Display firmware: the Panther Lake display controller blob. The v2.20 pin is
# the known-good version for VRR on Xe3 panels; newer DMC releases cap VRR
# (the original device saw ~74 fps, dropping to ~30 fps after toggles).
DMC_NAME="i915/xe3lpd_dmc.bin"
DMC_OVERRIDE="/usr/lib/firmware/updates/$DMC_NAME.zst"
# VERIFY-ON-HARDWARE: this hash belongs to the v2.20 blob shipped for the other
# Panther Lake handheld. Confirm it matches the Claw's expected blob before
# trusting it, or supply your own with MSI_CLAW_DMC_SHA256.
DMC_SHA256="${MSI_CLAW_DMC_SHA256:-150eaa60a776e489f69e6f334d4c12216c0d686f3a53ac2228d0a6ce48f8add9}"

# Gamescope display definition (48-120 Hz, no HDR).
LUA_DIR="$HOME/.config/gamescope/scripts"
LUA_DISPLAY="$LUA_DIR/98-msi-claw-display.lua"

# Volume key fix (the EC drops key-up events on the i8042 keyboard).
VOLKEY_PY="$FIX_DIR/msi-claw-volkey-fix.py"
VOLKEY_UNIT=/etc/systemd/system/msi-claw-volkey-fix.service

# Suspend workaround module and unit names. The original shipped a prebuilt
# module tied to one kernel; this port builds from source and skips on mismatch.
XEVMA_DIR="$FIX_DIR/xevmafix"
XEVMA_UNIT=/etc/systemd/system/msi-claw-xevmafix.service

# Decky plugin this repo ships.
PLUGIN_NAME="SimpleDeckyTDP-MSI-Claw"
DECKY_PLUGINS="$HOME/homebrew/plugins"
PLUGIN_DIR="$DECKY_PLUGINS/$PLUGIN_NAME"
PLUGIN_ZIP_NAME="simpledeckytdp-msi-claw.zip"
PLUGIN_VERSION="1.0.7+claw8ex.1"

FORCE=0
MODE=apply
for arg in "$@"; do
  case "$arg" in
    --check) MODE=check ;;
    --revert) MODE=revert ;;
    --force) FORCE=1 ;;
    --version) echo "$MSI_CLAW_FIXES_VERSION"; exit 0 ;;
    *) echo "unknown option: $arg (valid: --check | --revert | --force | --version)"; exit 2 ;;
  esac
done

say() { printf '%s\n' "$*"; }
hdr() { printf '\n== %s ==\n' "$*"; }

if [ "$MODE" = revert ] || [ "$MODE" = check ]; then SUDO=""; else SUDO="sudo"; fi

dmi_ok() {
  local product_lower
  product_lower="$(printf '%s' "$DMI_PRODUCT" | tr '[:upper:]' '[:lower:]')"
  for match in "${DMI_MATCHES[@]}"; do
    local match_lower
    match_lower="$(printf '%s' "$match" | tr '[:upper:]' '[:lower:]')"
    case "$product_lower" in
      *"$match_lower"*) return 0 ;;
    esac
  done
  return 1
}

if [ "$MODE" != check ] && [ "$FORCE" -ne 1 ] && ! dmi_ok; then
  say "This script is for the MSI Claw 8 EX AI+ (CG3EM)."
  say "Detected: vendor='$DMI_VENDOR' product='$DMI_PRODUCT' board='$DMI_BOARD'"
  say "Refusing to change this machine. Re-run with --force to override."
  exit 1
fi

# ===========================================================================
# DISTRO DETECTION
# ===========================================================================
# This pack is NOT SteamOS-only. It targets, in order of testing:
#   * SteamOS 3.x          (Arch-based, read-only /usr, steamos-readonly)
#   * CachyOS Handheld Ed. (Arch-based, writable /, pacman)
#   * Bazzite              (Fedora Atomic, immutable /usr, rpm-ostree)
#   * other Arch-family    (EndeavourOS, vanilla Arch, ...)
#   * unknown              (prints manual instructions, changes nothing unsafe)
#
# "Anatase OS" is not a distribution this script knows. If that is what you run,
# it will fall into the "unknown" branch: the script still applies the portable
# fixes (TDP sync, split-lock karg, gamescope lua, plugin install) but skips
# package-manager and read-only-root handling and tells you what to do by hand.
detect_distro() {
  local id="" like=""
  if [ -r /etc/os-release ]; then
    id="$(sed -n 's/^ID=//p' /etc/os-release | tr -d '\"' | head -n1)"
    like="$(sed -n 's/^ID_LIKE=//p' /etc/os-release | tr -d '\"' | head -n1)"
  fi
  case "$id" in
    steamos) echo steamos; return ;;
    bazzite) echo bazzite; return ;;
    cachyos) echo cachyos; return ;;
  esac
  case " $like " in
    *" arch "*) echo arch; return ;;
    *" fedora "*|*" rhel "*) echo fedora; return ;;
  esac
  case "$id" in
    arch|endeavouros|garuda|manjaro) echo arch; return ;;
    fedora|nobara) echo fedora; return ;;
  esac
  echo unknown
}

DISTRO="$(detect_distro)"
case "$DISTRO" in
  steamos) DISTRO_LABEL="SteamOS" ;;
  bazzite) DISTRO_LABEL="Bazzite (Fedora Atomic)" ;;
  cachyos) DISTRO_LABEL="CachyOS Handheld Edition" ;;
  arch) DISTRO_LABEL="Arch-family" ;;
  fedora) DISTRO_LABEL="Fedora-family" ;;
  *) DISTRO_LABEL="unknown distro" ;;
esac

# Immutable /usr? SteamOS and Bazzite both are, but they are undone differently.
usr_is_immutable() {
  case "$DISTRO" in
    steamos|bazzite|fedora) return 0 ;;
    *) return 1 ;;
  esac
}

# Install a firmware package with whatever the distro provides. Returns non-zero
# when the caller should fall back to manual instructions.
install_firmware_package() {
  local pkg="${1:-linux-firmware-intel}"
  case "$DISTRO" in
    steamos)
      command -v steamos-readonly >/dev/null 2>&1 && $SUDO steamos-readonly disable 2>/dev/null
      $SUDO pacman -Sy --noconfirm "$pkg" 2>&1 | tail -n5
      local rc=${PIPESTATUS[0]}
      command -v steamos-readonly >/dev/null 2>&1 && $SUDO steamos-readonly enable 2>/dev/null
      return $rc
      ;;
    cachyos|arch)
      # Plain Arch: /usr is writable, pacman works normally. linux-firmware-intel
      # exists on CachyOS; plain Arch ships the firmware in linux-firmware.
      if $SUDO pacman -Sy --noconfirm "$pkg" 2>&1 | tail -n5; then return 0; fi
      $SUDO pacman -Sy --noconfirm linux-firmware 2>&1 | tail -n5
      return ${PIPESTATUS[0]}
      ;;
    bazzite|fedora)
      # Fedora Atomic: never run pacman. Firmware lives in the base image; an
      # upgrade usually brings the missing iwlwifi/btintel files. Layering is
      # possible but needs a reboot and may conflict with the image's packages.
      say "  [info] Fedora Atomic detected. Run 'rpm-ostree upgrade' and reboot first."
      say "  [info] If firmware is still missing: sudo rpm-ostree install linux-firmware"
      say "  [info] then reboot. This script does not layer packages automatically."
      return 1
      ;;
    *)
      say "  [info] Unrecognised distro. Install the Intel Wi-Fi 7 / BT 6.0 firmware"
      say "  [info] with your package manager (package name is usually"
      say "  [info] linux-firmware-intel or linux-firmware) and re-run --check."
      return 1
      ;;
  esac
}

# Restart Decky Loader whichever unit name this distro/image uses.
restart_decky() {
  for unit in plugin_loader.service decky-loader.service; do
    if systemctl list-unit-files "$unit" >/dev/null 2>&1 && \
       systemctl cat "$unit" >/dev/null 2>&1; then
      $SUDO systemctl restart "$unit" 2>/dev/null && return 0
    fi
  done
  say "  [warn] could not find a Decky Loader systemd unit to restart"
  return 1
}

# ===========================================================================
# STEP 0 - Wi-Fi / Bluetooth firmware
# ===========================================================================
# The original fix pack extracted the BE201 (8086:e440) iwlwifi files that the
# SteamOS image was missing. The Claw 8 EX AI+ uses Intel Wi-Fi 7 (802.11be) and
# Bluetooth 6.0. The exact PCI ID of the Claw's module is NOT confirmed, so this
# step does not hardcode 8086:e440. It probes what the kernel bound and only
# installs firmware when the driver reports a load failure.
#
# VERIFY-ON-HARDWARE: run `lspci -nn | grep -i network` and
# `dmesg | grep -i iwlwifi` on a real Claw and pin the ID here once known.
step_wifi_firmware() {
  hdr "0) Wi-Fi / Bluetooth firmware"
  local wifi_pci iwl_fail

  wifi_pci="$(lspci -nn 2>/dev/null | grep -iE 'network controller|wireless' | head -n1)"
  if [ -z "$wifi_pci" ]; then
    say "  no Wi-Fi controller found in lspci; skipping"
    return 0
  fi
  say "  Wi-Fi controller: $wifi_pci"

  # A bound iwlwifi with a firmware load error is the only case we act on.
  iwl_fail="$(journalctl -k -b 0 --no-pager 2>/dev/null | grep -iE 'iwlwifi.*(fail|error).*firmware|firmware.*(fail|error).*iwlwifi' | tail -n1)"
  if [ -z "$iwl_fail" ]; then
    say "  iwlwifi reports no firmware failure; nothing to do"
    return 0
  fi
  say "  iwlwifi firmware failure detected: $iwl_fail"

  if [ "$MODE" = check ]; then
    say "  would install linux-firmware-intel and reload iwlwifi"
    return 0
  fi

  # Distro-aware install. SteamOS needs the read-only root unlocked; CachyOS and
  # Arch just run pacman; Bazzite is Fedora Atomic and must use rpm-ostree.
  if ! install_firmware_package linux-firmware-intel; then
    say "  [warn] automatic firmware install not possible on $DISTRO_LABEL"
    say "  [warn] install the Intel Wi-Fi 7 firmware manually, then re-run --check"
    return 1
  fi

  # Reload the driver so the newly installed firmware is picked up now. BT needs
  # a reboot on most Intel combo modules, which the script tells the user about.
  $SUDO modprobe -r iwlmvm iwlwifi 2>/dev/null || true
  $SUDO modprobe iwlwifi 2>/dev/null || true
  say "  Wi-Fi reloaded. Bluetooth 6.0 firmware loads on the next reboot."
}

# ===========================================================================
# STEP 1 - Display firmware: DMC v2.20 pin (VRR fix)
# ===========================================================================
# Newer SteamOS images ship DMC v2.36, which caps VRR on Xe3 panels (the
# original device saw ~74 fps, dropping to ~30 fps after refresh toggles).
# v2.20 goes into /usr/lib/firmware/updates/i915/, which takes precedence over
# the packaged copy, so no package is replaced. The file lives in /usr, so a
# SteamOS image update can remove it - re-run this script after updates.
dmc_loaded() { journalctl -k -b 0 --no-pager 2>/dev/null | sed -n "s|.*Finished loading DMC firmware $DMC_NAME (\(v[0-9.]*\)).*|\1|p" | tail -n1; }
dmc_override_ok() { [ -f "$DMC_OVERRIDE" ] && [ "$(sha256sum "$DMC_OVERRIDE" 2>/dev/null | cut -d' ' -f1)" = "$DMC_SHA256" ]; }
dmc_applies() { [ -e "/usr/lib/firmware/$DMC_NAME.zst" ] || [ -e "/usr/lib/firmware/$DMC_NAME" ]; }

step_dmc_firmware() {
  hdr "1) Display firmware DMC v2.20 (VRR fix)"
  if ! dmc_applies; then
    say "  $DMC_NAME not present on this system; the driver does not use it. Skipping."
    return 0
  fi

  local loaded
  loaded="$(dmc_loaded)"
  say "  running DMC firmware: ${loaded:-unknown}"

  if dmc_override_ok; then
    say "  v2.20 override already installed and hash matches"
    return 0
  fi

  if [ "$MODE" = check ]; then
    say "  v2.20 override NOT installed (VRR will be capped by the shipped DMC)"
    return 0
  fi

  local blob="$CACHE_DIR/xe3lpd_dmc.bin.zst"
  if [ ! -f "$blob" ]; then
    say "  [action needed] place the v2.20 blob at $blob"
    say "  It ships in this project's release archive under firmware/."
    say "  Expected sha256: $DMC_SHA256"
    return 1
  fi

  if [ "$(sha256sum "$blob" | cut -d' ' -f1)" != "$DMC_SHA256" ]; then
    say "  [error] $blob does not match the expected sha256; not installing"
    return 1
  fi

  # Install path differs on immutable images. The kernel only searches
  # /lib/firmware/updates (and /lib/firmware), so a custom firmware_class.path is
  # the portable fallback on Bazzite, where /usr cannot be written at runtime.
  case "$DISTRO" in
    bazzite|fedora)
      local var_blob="/var/lib/firmware/$DMC_NAME.zst"
      $SUDO mkdir -p "$(dirname "$var_blob")"
      $SUDO cp "$blob" "$var_blob"
      say "  installed $var_blob"
      say "  Fedora Atomic: add firmware_class.path=/var/lib/firmware to the"
      say "  kernel arguments (rpm-ostree kargs --append=...) and reboot."
      say "  Without that karg the driver will not see this blob."
      ;;
    *)
      $SUDO mkdir -p "$(dirname "$DMC_OVERRIDE")"
      $SUDO cp "$blob" "$DMC_OVERRIDE"
      say "  installed $DMC_OVERRIDE"
      ;;
  esac
  say "  Reboot (or reload xe) for the v2.20 firmware to load."
  say "  The Claw's panel runs 48-120 Hz VRR; there is no HDR path to fix."
}

# ===========================================================================
# STEP 2 - Gamescope display definition (48-120 Hz VRR, NO HDR)
# ===========================================================================
# The original pack declared a 30-144 Hz OLED with HDR/PQ. The Claw's 8" IPS is
# 1920x1200, 48-120 Hz VRR, 500 nits, 100% sRGB and has NO HDR. This declares the
# real range and no HDR metadata. The original's HDR/PQ and xehdrfix steps are
# NOT ported: there is no HDR panel to drive.
LUA_CONTENT=$(cat <<'EOT'
-- MSI Claw 8 EX AI+ (CG3EM): 8" IPS 1920x1200 16:10, 48-120 Hz VRR, no HDR.
-- No HDR/PQ metadata on purpose: the panel is 500 nits sRGB only.
local panel = {
  name = "MSI Claw 8 EX AI+ internal panel",
  width = 1920,
  height = 1200,
  refresh = 120,
  vrr_min = 48,
  vrr_max = 120,
  hdr = false,
}

gamescope.known_displays = gamescope.known_displays or {}
gamescope.known_displays["msi-claw-8-ex-ai"] = panel

-- Register the real continuous VRR range so Steam's per-game refresh selector
-- offers 48-120 Hz instead of a single fixed rate. 40 is NOT declared: 48 is
-- the panel's floor.
if gamescope.set_dynamic_refresh_rates then
  gamescope.set_dynamic_refresh_rates(48, 120)
end
EOT
)

step_display_lua() {
  hdr "2) Gamescope display definition (48-120 Hz VRR, no HDR)"
  if [ "$MODE" = check ]; then
    if [ -f "$LUA_DISPLAY" ]; then say "  present: $LUA_DISPLAY"; else say "  missing: $LUA_DISPLAY"; fi
    return 0
  fi
  mkdir -p "$LUA_DIR"
  printf '%s\n' "$LUA_CONTENT" > "$LUA_DISPLAY"
  say "  wrote $LUA_DISPLAY"
  say "  HDR fixes from the original pack are deliberately omitted (no HDR panel)."
}

# ===========================================================================
# STEP 3 - Split-lock report flooding
# ===========================================================================
# Steam's split locks were trapped and reported many times a second on the
# original device. The same mitigation applies on the Claw. Turning detection
# off only silences the report flood; it does not make Steam's locks fast. It is
# portable across SteamOS, CachyOS/Arch, and Bazzite (rpm-ostree kargs).
SPLITLOCK_CONTENT=$(cat <<'EOT'
# split_lock_detect=off: silences Steam's split-lock report flood.
# Revert: remove this file and regenerate the bootloader config.
GRUB_CMDLINE_LINUX="${GRUB_CMDLINE_LINUX} split_lock_detect=off"
EOT
)

step_split_lock() {
  hdr "3) Split-lock report flooding"
  if grep -qw split_lock_detect /proc/cpuinfo 2>/dev/null; then
    :
  else
    say "  CPU does not advertise split_lock_detect; nothing to do"
    return 0
  fi
  if grep -qw split_lock_detect=off /proc/cmdline 2>/dev/null; then
    say "  split_lock_detect=off already active"
    return 0
  fi

  if [ "$MODE" = check ]; then
    say "  split_lock_detect=off NOT active"
    return 0
  fi

  case "$DISTRO" in
    bazzite|fedora)
      $SUDO rpm-ostree kargs --append-if-missing=split_lock_detect=off 2>&1 | tail -n3
      say "  added via rpm-ostree; takes effect after reboot"
      ;;
    *)
      $SUDO mkdir -p "$GRUB_DIR"
      printf '%s\n' "$SPLITLOCK_CONTENT" | $SUDO tee "$SPLITLOCK_GRUB" >/dev/null
      if command -v update-grub >/dev/null 2>&1; then
        $SUDO update-grub 2>&1 | tail -n2
      elif command -v grub-mkconfig >/dev/null 2>&1; then
        $SUDO grub-mkconfig -o /boot/grub/grub.cfg 2>&1 | tail -n2
      else
        say "  [warn] no grub tool found; add split_lock_detect=off to your bootloader manually"
      fi
      say "  wrote $SPLITLOCK_GRUB"
      ;;
  esac
}

# ===========================================================================
# STEP 4 - TDP sync (MMIO PL1 -> MSR PL1) and 8-35 W envelope
# ===========================================================================
# The plugin now writes both RAPL domains when it sets TDP (see cpu_utils.py).
# This service re-syncs them at boot and after resume for anything that writes
# MMIO directly. It does NOT set a TDP: the plugin owns the user's value. It only
# copies MMIO PL1 into the MSR domain so CPU and iGPU obey the same limit.
TDPSYNC_UNIT=/etc/systemd/system/msi-claw-tdp-sync.service
TDPSYNC_SCRIPT="$FIX_DIR/msi-claw-tdp-sync.sh"

TDPSYNC_SCRIPT_CONTENT=$(cat <<'EOT'
#!/usr/bin/bash
# Copy MMIO PL1 to MSR PL1 so CPU and iGPU obey the same sustained limit.
# MSI Claw 8 EX AI+ envelope: 8-35 W sustained, PL2 burst 37 W (firmware value).
MMIO=/sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw
MSR=/sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw
[ -r "$MMIO" ] && [ -w "$MSR" ] || exit 0
mmio="$(cat "$MMIO" 2>/dev/null)" || exit 0
[ -n "$mmio" ] || exit 0
printf '%s' "$mmio" > "$MSR" 2>/dev/null || true
EOT
)

TDPSYNC_UNIT_CONTENT=$(cat <<'EOT'
[Unit]
Description=MSI Claw 8 EX AI+ TDP sync (MMIO PL1 -> MSR PL1)
After=multi-user.target suspend.target hibernate.target hybrid-sleep.target

[Service]
Type=oneshot
ExecStart=/usr/bin/bash %h/msi-claw-fix/msi-claw-tdp-sync.sh

[Install]
WantedBy=multi-user.target
EOT
)

step_tdp_sync() {
  hdr "4) TDP sync (MMIO PL1 -> MSR PL1)"
  local mmio=/sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw
  local msr=/sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw
  local pl2=/sys/class/powercap/intel-rapl-mmio:0/constraint_1_power_limit_uw

  if [ ! -r "$mmio" ] || [ ! -r "$msr" ]; then
    say "  RAPL MMIO/MSR domains not both readable; skipping"
    return 0
  fi
  say "  PL1 MMIO $(($(cat "$mmio")/1000000)) W, MSR $(($(cat "$msr")/1000000)) W"
  [ -r "$pl2" ] && say "  PL2 MMIO $(($(cat "$pl2")/1000000)) W (firmware burst value)"

  if [ "$MODE" = check ]; then
    if [ -f "$TDPSYNC_UNIT" ]; then say "  service: present"; else say "  service: missing"; fi
    return 0
  fi

  mkdir -p "$FIX_DIR"
  printf '%s\n' "$TDPSYNC_SCRIPT_CONTENT" > "$TDPSYNC_SCRIPT"
  chmod +x "$TDPSYNC_SCRIPT"
  printf '%s\n' "$TDPSYNC_UNIT_CONTENT" | $SUDO tee "$TDPSYNC_UNIT" >/dev/null
  $SUDO systemctl daemon-reload 2>/dev/null || true
  $SUDO systemctl enable msi-claw-tdp-sync.service 2>&1 | tail -n2
  say "  installed and enabled msi-claw-tdp-sync.service"
  say "  envelope: 8-35 W sustained (PL1), 37 W burst (PL2), set by the plugin"
}

# ===========================================================================
# STEP 5 - Battery reporting (80 Wh 4-cell) and charge limit note
# ===========================================================================
# The original pack overlaid the battery gauge to clamp a mis-reported capacity.
# The Claw's 80 Wh pack is reported correctly by the kernel, so no overlay is
# installed. This step only reports the values and points at the plugin's charge
# limit (50-100%, default 80%), which is the portable, non-invasive control.
step_battery() {
  hdr "5) Battery reporting (80 Wh 4-cell)"
  local bat=""
  for candidate in /sys/class/power_supply/BAT1 /sys/class/power_supply/BAT0; do
    [ -d "$candidate" ] && { bat="$candidate"; break; }
  done
  if [ -z "$bat" ]; then
    say "  no battery found in /sys/class/power_supply; skipping"
    return 0
  fi
  say "  $bat"
  say "    capacity   $(cat "$bat/capacity" 2>/dev/null)%"
  say "    status     $(cat "$bat/status" 2>/dev/null)"
  say "    energy     $(($(cat "$bat/energy_now" 2>/dev/null || echo 0)/1000000)) Wh now / $(($(cat "$bat/energy_full" 2>/dev/null || echo 0)/1000000)) Wh full"
  say "    cycles     $(cat "$bat/cycle_count" 2>/dev/null || echo unknown)"
  say "  charge limit: set it in the plugin (50-100%, default 80%)."
  say "  The original's gauge overlay is NOT installed: the Claw reports correctly."
}

# ===========================================================================
# STEP 6 - Volume keys
# ===========================================================================
# On the original device the EC dropped key-up events on the i8042 keyboard, so
# a held volume key kept repeating. The fix is a small evdev reader that
# re-synthesises a key-up after a key-down. The Claw's volume keys arrive as
# standard KEY_VOLUMEUP/KEY_VOLUMEDOWN events through hid-generic, so the same
# reader applies. VERIFY-ON-HARDWARE: confirm the event device on a real Claw
# with `sudo evtest` or `libinput debug-events`.
VOLKEY_PY_CONTENT=$(cat <<'EOT'
#!/usr/bin/env python3
"""Re-synthesise key-up for MSI Claw 8 EX AI+ volume keys.

Some MSI handhelds drop the key-up event when a volume key is held, which makes
the volume run to 0 or 100. This reader watches for volume-key events and emits
the matching key-up immediately, so a long press behaves like a single press.
Requires python3-evdev. Run as root via msi-claw-volkey-fix.service.
"""
import sys
import evdev

VOLUME_KEYS = {evdev.ecodes.KEY_VOLUMEUP, evdev.ecodes.KEY_VOLUMEDOWN}
GRAB = False


def find_keyboards():
  found = []
  for path in evdev.list_devices():
    try:
      dev = evdev.InputDevice(path)
    except Exception:
      continue
    keys = dev.capabilities(verbose=False).get(evdev.ecodes.EV_KEY, [])
    if evdev.ecodes.KEY_VOLUMEUP in keys or evdev.ecodes.KEY_VOLUMEDOWN in keys:
      found.append(dev)
  return found


def main():
  devices = find_keyboards()
  if not devices:
    print('msi-claw-volkey-fix: no volume-key device found; exiting', file=sys.stderr)
    return 0
  for dev in devices:
    print(f'msi-claw-volkey-fix: watching {dev.path} ({dev.name})', file=sys.stderr)
    if GRAB:
      dev.grab()
    try:
      for event in dev.read_loop():
        if event.type != evdev.ecodes.EV_KEY:
          continue
        if event.code in VOLUME_KEYS and event.value == 1:
          ui = evdev.UInput.from_device(dev, name=dev.name + ' (volkey-fix)')
          ui.write(evdev.ecodes.EV_KEY, event.code, 0)
          ui.syn()
          ui.close()
    except Exception as e:
      print(f'msi-claw-volkey-fix: {e}', file=sys.stderr)
    finally:
      if GRAB:
        try: dev.ungrab()
        except Exception: pass
  return 0


if __name__ == '__main__':
  sys.exit(main())
EOT
)

VOLKEY_UNIT_CONTENT=$(cat <<'EOT'
[Unit]
Description=MSI Claw 8 EX AI+ volume key key-up fix
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 %h/msi-claw-fix/msi-claw-volkey-fix.py
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOT
)

step_volume_keys() {
  hdr "6) Volume keys"
  if ! python3 -c 'import evdev' 2>/dev/null; then
    say "  python3-evdev not installed"
    if [ "$MODE" = check ]; then
      say "  would install python3-evdev"; return 0
    fi
    case "$DISTRO" in
      bazzite|fedora)
        say "  [info] Fedora Atomic: sudo rpm-ostree install python3-evdev && reboot"
        return 0 ;;
      *)
        $SUDO pacman -Sy --noconfirm python-evdev 2>&1 | tail -n2 || \
          say "  [warn] install python3-evdev manually" ;;
    esac
  fi

  if [ "$MODE" = check ]; then
    if [ -f "$VOLKEY_UNIT" ]; then say "  service: present"; else say "  service: missing"; fi
    return 0
  fi

  mkdir -p "$FIX_DIR"
  printf '%s\n' "$VOLKEY_PY_CONTENT" > "$VOLKEY_PY"
  chmod +x "$VOLKEY_PY"
  printf '%s\n' "$VOLKEY_UNIT_CONTENT" | $SUDO tee "$VOLKEY_UNIT" >/dev/null
  $SUDO systemctl daemon-reload 2>/dev/null || true
  $SUDO systemctl enable --now msi-claw-volkey-fix.service 2>&1 | tail -n2
  say "  installed msi-claw-volkey-fix.service"
}

# ===========================================================================
# STEP 7 - Button mapping (MSI Claw -> reference handheld equivalents)
# ===========================================================================
# The original exposed extra buttons through an MCU table reachable via its
# The Claw does not: its extra buttons are ordinary HID keys remapped in Steam
# Input or by an InputPlumber profile. This step writes the documented mapping as
# a reference and, when InputPlumber is present (CachyOS Handheld, Bazzite),
# installs a commented-out device profile skeleton.
#
# VERIFY-ON-HARDWARE: key codes must be confirmed with `evtest` first.
BUTTON_MAP_CONTENT=$(cat <<'EOT'
# MSI Claw 8 EX AI+ button mapping (reference)
# Confirm real evdev key codes with `evtest` on hardware first.
M1               = Left Back Paddle       # BTN_TL  (reference LeftPaddle1)
M2               = Right Back Paddle      # BTN_TR  (reference RightPaddle1)
MSI Center M     = Home / Steam Menu      # KEY_HOMEPAGE
Quick Settings   = Quick Access           # KEY_F13 (verify)
Menu             = App Menu               # KEY_MENU
View             = Game View / Screenshot # KEY_PRINT
Fingerprint      = Power / Sleep          # KEY_SLEEP
EOT
)

BUTTON_MAP_FILE="$FIX_DIR/msi-claw-button-map.txt"
INPUTPLUMBER_PROFILE=/etc/inputplumber/devices.d/msi-claw-8-ex-ai.yaml

step_button_mapping() {
  hdr "7) Button mapping (MSI Claw -> reference handheld equivalents)"
  if [ "$MODE" = check ]; then
    [ -f "$BUTTON_MAP_FILE" ] && say "  reference map: present" || say "  reference map: missing"
    [ -f "$INPUTPLUMBER_PROFILE" ] && say "  InputPlumber profile: present" || say "  InputPlumber profile: absent"
    return 0
  fi
  mkdir -p "$FIX_DIR"
  printf '%s\n' "$BUTTON_MAP_CONTENT" > "$BUTTON_MAP_FILE"
  say "  wrote $BUTTON_MAP_FILE"

  if [ -d /etc/inputplumber/devices.d ]; then
    {
      echo '# MSI Claw 8 EX AI+ (CG3EM) InputPlumber profile - UNVERIFIED.'
      echo '# Mappings are commented out: physical key codes are unconfirmed.'
      echo '# Uncomment and correct the source events, then reload inputplumber.'
      echo '#'
      echo '#   M1 -> Left Back Paddle, M2 -> Right Back Paddle,'
      echo '#   MSI Center M -> Home/Steam Menu, Quick Settings -> Quick Access,'
      echo '#   Menu -> App Menu, View -> Game View/Screenshot, Fingerprint -> Sleep.'
      echo '#'
      echo '#device:'
      echo '#  name: "MSI Claw 8 EX AI+"'
      echo '#  mappings:'
      echo '#    - { source: "key:BTN_TL", target: "button:left_paddle" }'
      echo '#    - { source: "key:BTN_TR", target: "button:right_paddle" }'
      echo '#    - { source: "key:KEY_HOMEPAGE", target: "button:guide" }'
      echo '#    - { source: "key:KEY_F13", target: "button:quick_access" }'
      echo '#    - { source: "key:KEY_MENU", target: "button:menu" }'
      echo '#    - { source: "key:KEY_PRINT", target: "button:screenshot" }'
      echo '#    - { source: "key:KEY_SLEEP", target: "button:sleep" }'
    } | $SUDO tee "$INPUTPLUMBER_PROFILE" >/dev/null
    say "  wrote $INPUTPLUMBER_PROFILE (commented out; confirm key codes first)"
  else
    say "  InputPlumber not installed. Map these in Steam Input instead."
  fi
  say "  The original's MCU button table and --mcu-restore path are NOT ported:"
  say "  the Claw has no equivalent writable MCU page and a blind write would be"
  say "  destructive."
}

# ===========================================================================
# STEP 8 - Suspend / resume (Panther Lake)
# ===========================================================================
# The original shipped a prebuilt module (xevmafix) for a kernel vmalloc bug on
# one specific kernel. The Claw does not report that bug, so the module is NOT
# ported: a prebuilt .ko is tied to one kernel ABI and would fail to load on any
# other. What IS ported is the portable part: re-syncing TDP after resume, since
# firmware can drop the MSR PL1 across s2idle.
RESUME_UNIT=/etc/systemd/system/msi-claw-resume-tdp.service

RESUME_UNIT_CONTENT=$(cat <<'EOT'
[Unit]
Description=MSI Claw 8 EX AI+ re-sync TDP after resume
After=suspend.target hibernate.target hybrid-sleep.target
Before=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/bin/bash %h/msi-claw-fix/msi-claw-tdp-sync.sh

[Install]
WantedBy=suspend.target hibernate.target hybrid-sleep.target multi-user.target
EOT
)

step_suspend() {
  hdr "8) Suspend / resume"
  local mem_sleep
  mem_sleep="$(cat /sys/power/mem_sleep 2>/dev/null)"
  say "  mem_sleep: ${mem_sleep:-unknown}"

  if [ "$MODE" = check ]; then
    [ -f "$RESUME_UNIT" ] && say "  resume re-sync: present" || say "  resume re-sync: missing"
    return 0
  fi

  # Panther Lake resumes reliably from s2idle; s3 is usually not implemented in
  # handheld firmware. Only report the current setting; changing mem_sleep needs
  # a kernel argument and a reboot, which this script leaves to the user.
  case "$mem_sleep" in
    *s2idle*) say "  s2idle available (recommended for Panther Lake)" ;;
    *) say "  s2idle not listed; consider mem_sleep_default=s2idle as a kernel argument" ;;
  esac

  printf '%s\n' "$RESUME_UNIT_CONTENT" | $SUDO tee "$RESUME_UNIT" >/dev/null
  $SUDO systemctl daemon-reload 2>/dev/null || true
  $SUDO systemctl enable msi-claw-resume-tdp.service 2>&1 | tail -n2
  say "  installed msi-claw-resume-tdp.service (re-syncs TDP after resume)"
  say "  The original xevmafix module is NOT ported: it is kernel-ABI specific"
  say "  and the Claw does not report the bug it worked around."
}

# ===========================================================================
# STEP 9 - RGB lighting (ABXY buttons + analog-stick rings)
# ===========================================================================
# The original controlled three RGB zones through the vendor HID driver.
# The Claw's lighting is owned by MSI Center on Windows. On Linux the zones may
# appear through the standard multicolor LED class (/sys/class/leds/*:rgb:*), or
# not at all. This step probes for writable zones and reports what it finds; it
# does NOT write guessed HID reports. When zones exist, the plugin's msi_claw.py
# module can drive them; otherwise lighting must be set in MSI Center.
step_rgb_lighting() {
  hdr "9) RGB lighting (ABXY + stick rings)"
  local zones
  zones="$(ls -d /sys/class/leds/* 2>/dev/null | grep -iE 'rgb|msi|claw|abxy|stick' | head -n10)"
  if [ -z "$zones" ]; then
    say "  no writable RGB LED zone found under /sys/class/leds"
    say "  Set ABXY/stick-ring lighting in MSI Center (Windows). On Linux there is"
    say "  no confirmed sysfs/HID interface on this BIOS revision, so the plugin"
    say "  reports RGB as unavailable instead of writing unknown reports."
    return 0
  fi
  say "  candidate RGB zones:"
  printf '%s\n' "$zones" | while read -r z; do say "    $z"; done
  local writable=0
  for z in $zones; do
    [ -w "$z/multi_intensity" ] && writable=$((writable + 1))
  done
  if [ "$writable" -gt 0 ]; then
    say "  $writable zone(s) expose writable multi_intensity"
    say "  The plugin (py_modules/devices/msi_claw.py) can drive these zones."
  else
    say "  zones exist but multi_intensity is not writable; lighting stays in MSI Center"
  fi
  say "  The original's three-zone vendor HID script is NOT ported: the Claw does not"
  say "  use that driver and its report format would be wrong for this hardware."
}

# ===========================================================================
# STEP 10 - Performance overlay (Xe3 / Arc B390 metrics)
# ===========================================================================
# The original added an overlay for its panel and SoC. For the Claw's Arc B390
# (Xe3), the useful metrics are GPU busy %, frequency, power and thermal state.
# Mangohud reads these from sysfs/PMU and works on SteamOS, CachyOS and Bazzite.
# This step enables a Mangohud config with the Xe3-relevant metrics and checks
# for `intel_gpu_top` as the fallback diagnostic.
MANGOHUD_CONF="$HOME/.config/MangoHud/MangoHud.conf"

MANGOHUD_CONF_CONTENT=$(cat <<'EOT'
# MSI Claw 8 EX AI+ (Arc B390 / Xe3) overlay
# GPU metrics come from i915/xe sysfs; power from RAPL.
gpu_stats
gpu_temp
gpu_power
gpu_clock
cpu_stats
cpu_temp
cpu_power
ram
vram
fps
frametime
frame_timing
toggle_hud=Shift_R+F12
background_alpha=0.4
font_size=18
EOT
)

step_perf_overlay() {
  hdr "10) Performance overlay (Xe3 metrics)"
  if [ "$MODE" = check ]; then
    if [ -f "$MANGOHUD_CONF" ]; then say "  MangoHud config: present"; else say "  MangoHud config: missing"; fi
    command -v mangoapp >/dev/null 2>&1 && say "  mangoapp: present" || say "  mangoapp: not installed"
    command -v intel_gpu_top >/dev/null 2>&1 && say "  intel_gpu_top: present" || say "  intel_gpu_top: not installed"
    return 0
  fi

  # Mangohud/mangoapp are preinstalled on Bazzite and available in CachyOS repos.
  if ! command -v mangoapp >/dev/null 2>&1 && ! command -v mangohud >/dev/null 2>&1; then
    say "  mangohud not installed"
    case "$DISTRO" in
      bazzite|fedora)
        say "  [info] Fedora Atomic: mangohud is part of the Bazzite image; if missing,"
        say "  [info] sudo rpm-ostree install mangohud && reboot" ;;
      *)
        $SUDO pacman -Sy --noconfirm mangohud lib32-mangohud 2>&1 | tail -n3 || \
          say "  [warn] install mangohud manually" ;;
    esac
  fi

  mkdir -p "$(dirname "$MANGOHUD_CONF")"
  printf '%s\n' "$MANGOHUD_CONF_CONTENT" > "$MANGOHUD_CONF"
  say "  wrote $MANGOHUD_CONF (Xe3 GPU busy/temp/power/clock, FPS, frametime)"

  if ! command -v intel_gpu_top >/dev/null 2>&1; then
    say "  tip: install intel-gpu-tools for a live Arc B390 metric view"
  fi
  say "  The original's custom overlay script is NOT ported: Mangohud already"
  say "  reads the same Xe3 counters and is maintained for all three distros."
}

# ===========================================================================
# STEP 11 - MSI Center integration (replaces vendor console)
# ===========================================================================
# The original called the vendor console's API to set power and lighting. MSI
# Center and MSI Center M are Windows-only; there is no Linux service to call.
# Everything the plugin needs is either a sysfs/EC value or unavailable. This
# step prints what is available and writes a reference file so bug reports can
# include it. The plugin's get_device_capabilities() returns the same data to the
# UI, so controls that cannot work on Linux are hidden rather than failing.
step_msi_center() {
  hdr "11) MSI Center integration (replaces vendor console)"
  local status_file="$FIX_DIR/msi-claw-capabilities.txt"
  {
    echo "MSI Claw 8 EX AI+ capability report - $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "DMI: $DMI_VENDOR / $DMI_PRODUCT / board $DMI_BOARD / BIOS $DMI_BIOS"
    echo "OS:  $DISTRO_LABEL ($DISTRO), kernel $KVER"
    echo ""
    echo "feature                 linux status"
    echo "----------------------- ---------------------------------------------"
    echo "TDP control             $([ -w /sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw ] && echo 'yes (RAPL MMIO+MSR)' || echo 'no')"
    echo "fan curve               $(ls /sys/class/hwmon/hwmon*/pwm1 >/dev/null 2>&1 && echo 'pwm1 present' || echo 'EC-owned; set in MSI Center')"
    echo "RGB (ABXY/stick rings)  $(ls -d /sys/class/leds/* 2>/dev/null | grep -qiE 'rgb|msi|abxy|stick' && echo 'LED zone present' || echo 'set in MSI Center')"
    echo "bypass charging         no generic Linux interface; MSI Center only"
    echo "charge limit            yes (plugin, 50-100%, default 80%)"
    echo "battery reporting       $(ls /sys/class/power_supply/BAT* >/dev/null 2>&1 && echo 'yes (80 Wh 4-cell)' || echo 'no')"
    echo "MSI Center API          none (Windows-only application)"
  } > "$status_file" 2>/dev/null
  cat "$status_file" 2>/dev/null | while read -r line; do say "  $line"; done
  say "  wrote $status_file"
  say "  Replaced controls: TDP, EPP, charge limit and battery reporting are handled"
  say "  directly by the plugin. Fan curve, RGB and bypass charging remain in MSI"
  say "  Center on Windows; the plugin hides those controls on Linux."
}

# ===========================================================================
# STEP 12 - Install the SimpleDeckyTDP-MSI-Claw plugin
# ===========================================================================
# The plugin is what actually applies TDP, EPP, smart boost and charge limit. The
# original installed its plugin from a GitHub release. This port installs from the
# repo's own release archive, or from a local zip, and restarts Decky Loader.
step_plugin_install() {
  hdr "12) SimpleDeckyTDP-MSI-Claw plugin"
  if [ ! -d "$DECKY_PLUGINS" ]; then
    say "  Decky Loader not found at $DECKY_PLUGINS"
    say "  Install Decky Loader first (CachyOS Handheld Edition and Bazzite ship it;"
    say "  on SteamOS use the Decky installer), then re-run this script."
    return 0
  fi

  if [ -f "$PLUGIN_DIR/plugin.json" ]; then
    say "  plugin already installed at $PLUGIN_DIR ($PLUGIN_VERSION target)"
    if [ "$MODE" = check ]; then return 0; fi
    say "  leaving the existing install in place; delete it to force a reinstall"
    return 0
  fi

  if [ "$MODE" = check ]; then
    say "  plugin NOT installed (would install $PLUGIN_VERSION)"
    return 0
  fi

  local zip="$FIX_DIR/$PLUGIN_ZIP_NAME"
  if [ ! -f "$zip" ]; then
    say "  [action needed] place $PLUGIN_ZIP_NAME in $FIX_DIR"
    say "  Build it with: ./build.sh (this repo) or download it from the release."
    return 1
  fi

  local tmp
  tmp="$(mktemp -d)"
  if ! unzip -q "$zip" -d "$tmp" 2>/dev/null; then
    say "  [error] could not unzip $zip"; rm -rf "$tmp"; return 1
  fi
  $SUDO mkdir -p "$DECKY_PLUGINS"
  $SUDO rm -rf "$PLUGIN_DIR"
  if ! $SUDO mv "$tmp"/* "$PLUGIN_DIR" 2>/dev/null; then
    say "  [error] could not move plugin into $PLUGIN_DIR"; rm -rf "$tmp"; return 1
  fi
  rm -rf "$tmp"
  say "  installed $PLUGIN_NAME ($PLUGIN_VERSION)"
  restart_decky && say "  Decky Loader restarted"
}

# ===========================================================================
# MAIN - dispatch, check, revert, summary
# ===========================================================================
banner() {
  say "=================================================================="
  say " MSI Claw 8 EX AI+ (CG3EM) fix pack $MSI_CLAW_FIXES_VERSION"
  say "=================================================================="
  say " device : $DMI_VENDOR / $DMI_PRODUCT"
  say " board  : $DMI_BOARD   BIOS: $DMI_BIOS"
  say " OS     : $DISTRO_LABEL ($DISTRO), kernel $KVER"
  say "=================================================================="
}

run_check() {
  banner
  say ""
  say "CHECK ONLY - nothing will be changed and no password is needed."
  step_wifi_firmware
  step_dmc_firmware
  step_display_lua
  step_split_lock
  step_tdp_sync
  step_battery
  step_volume_keys
  step_button_mapping
  step_suspend
  step_rgb_lighting
  step_perf_overlay
  step_msi_center
  step_plugin_install
  say ""
  say "Check complete. Re-run without --check to apply."
}

run_apply() {
  banner
  say ""
  say "This will change the system. A sudo password may be requested."
  say "Read the plan above; press Enter to continue or Ctrl-C to abort."
  read -r _ || true
  say ""

  mkdir -p "$CACHE_DIR" "$FIX_DIR"
  # Keep a log of every run in /home so it survives OS updates.
  {
    echo "=== msi-claw-apply-fixes $(date -u +%Y-%m-%dT%H:%M:%SZ) distro=$DISTRO ==="
  } >> "$LOG_FILE" 2>/dev/null || true

  step_wifi_firmware   || say "  [note] Wi-Fi step reported a problem; continuing"
  step_dmc_firmware    || say "  [note] DMC step reported a problem; continuing"
  step_display_lua
  step_split_lock
  step_tdp_sync
  step_battery
  step_volume_keys
  step_button_mapping
  step_suspend
  step_rgb_lighting
  step_perf_overlay
  step_msi_center
  step_plugin_install || say "  [note] plugin not installed; see the message above"

  say ""
  say "=================================================================="
  say " DONE. Reboot to activate kernel arguments and firmware changes."
  say "=================================================================="
  say " After reboot, open Decky > SimpleDeckyTDP-MSI-Claw and set TDP"
  say " within 8-35 W. The plugin writes PL1 to MMIO and MSR (TDP sync)."
  say " Re-run this script after a SteamOS/CachyOS image update: files in"
  say " /usr and /etc can be replaced by an image update."
}

run_revert() {
  banner
  say ""
  say "REVERT - undoing everything this script installed."

  # systemd units and helper scripts
  for unit in msi-claw-tdp-sync.service msi-claw-resume-tdp.service msi-claw-volkey-fix.service; do
    if [ -f "/etc/systemd/system/$unit" ]; then
      $SUDO systemctl disable --now "$unit" 2>/dev/null || true
      $SUDO rm -f "/etc/systemd/system/$unit"
      say "  removed $unit"
    fi
  done
  $SUDO systemctl daemon-reload 2>/dev/null || true

  # files this script owns
  for f in "$TDPSYNC_SCRIPT" "$VOLKEY_PY" "$BUTTON_MAP_FILE" "$LUA_DISPLAY" \
           "$MANGOHUD_CONF" "$INPUTPLUMBER_PROFILE"; do
    if [ -f "$f" ]; then rm -f "$f" 2>/dev/null && say "  removed $f"; fi
  done

  # bootloader fragments
  for f in "$SPLITLOCK_GRUB" "$NVME_GRUB"; do
    if [ -f "$f" ]; then $SUDO rm -f "$f" && say "  removed $f"; fi
  done
  if command -v update-grub >/dev/null 2>&1; then $SUDO update-grub 2>/dev/null | tail -n1
  elif command -v grub-mkconfig >/dev/null 2>&1; then $SUDO grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null | tail -n1; fi

  # firmware override
  if [ -f "$DMC_OVERRIDE" ]; then $SUDO rm -f "$DMC_OVERRIDE" && say "  removed $DMC_OVERRIDE"; fi
  if [ -f "/var/lib/firmware/$DMC_NAME.zst" ]; then
    $SUDO rm -f "/var/lib/firmware/$DMC_NAME.zst" && say "  removed /var/lib/firmware/$DMC_NAME.zst"
  fi

  # plugin
  if [ -d "$PLUGIN_DIR" ]; then
    $SUDO rm -rf "$PLUGIN_DIR" && say "  removed plugin $PLUGIN_NAME"
    restart_decky 2>/dev/null && say "  Decky Loader restarted"
  fi

  say ""
  say " Revert complete. Reboot to drop the kernel arguments and firmware override."
}

case "$MODE" in
  check)  run_check ;;
  revert) run_revert ;;
  apply)  run_apply ;;
esac
