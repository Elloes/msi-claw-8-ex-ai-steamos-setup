import glob
import os
from devices import rog_ally
from plugin_settings import get_nested_setting
import device_utils
from time import sleep

# ---------------------------------------------------------------------------
# MSI Claw 8 EX AI+ charge limit (80 Wh 4-cell Li-polymer)
# ---------------------------------------------------------------------------
# The plugin's original charge-limit support was ROG Ally only. The Claw's
# charge cap is a firmware/EC feature that MSI Center exposes on Windows. On
# Linux the same EC value is usually reachable through the standard power
# supply class. We probe for it instead of assuming:
#
#   /sys/class/power_supply/BAT1/charge_control_end_threshold
#   /sys/class/power_supply/BAT0/charge_control_end_threshold
#
# If MSI's EC does not expose the attribute (some Claw BIOS revisions only
# allow the cap through MSI Center / ACPI-WMI), supports_charge_limit()
# returns False and the UI hides the control. That is a documented hardware
# limitation, not a bug in the plugin. Set the cap in MSI Center on Windows,
# or in the MSI Center M equivalent on SteamOS, before switching.
#
# BYPASS CHARGING: MSI Center's "bypass charging" (run from AC without
# charging the battery) has no generic Linux sysfs interface as of writing.
# See devices/msi_claw.py, which documents the ACPI/WMI probes that would be
# needed and returns False until such an interface is confirmed on hardware.
MSI_CHARGE_THRESHOLD_ATTRIBUTES = [
  'charge_control_end_threshold',
  'charge_stop_threshold',
]
MSI_CHARGE_LIMIT_MIN = 50
MSI_CHARGE_LIMIT_MAX = 100
MSI_CHARGE_LIMIT_DEFAULT = 80   # 80 Wh pack, 80% is the usual long-life default
MSI_CHARGE_LIMIT_STEP = 5

def msi_charge_threshold_path():
  """Return the first writable charge-threshold sysfs file, or None."""
  for attribute in MSI_CHARGE_THRESHOLD_ATTRIBUTES:
    for path in glob.glob(f'/sys/class/power_supply/*/{attribute}'):
      try:
        if os.access(path, os.W_OK):
          return path
      except Exception:
        continue
  return None

def get_range_info():
  if device_utils.is_rog_ally_series():
    default = 100
    step = 5
    return [[charge_limit_min(), 100], default, step]
  if device_utils.is_msi_claw_8_ex_ai() and supports_charge_limit():
    return [[MSI_CHARGE_LIMIT_MIN, MSI_CHARGE_LIMIT_MAX],
            MSI_CHARGE_LIMIT_DEFAULT, MSI_CHARGE_LIMIT_STEP]
  return None

def charge_limit_min():
  if device_utils.is_rog_ally_series():
    return 70
  if device_utils.is_msi_claw_8_ex_ai():
    return MSI_CHARGE_LIMIT_MIN

  return 100

def get_current_charge_limit():
  if device_utils.is_rog_ally_series():
    return rog_ally.get_current_charge_limit()
  if device_utils.is_msi_claw_8_ex_ai():
    path = msi_charge_threshold_path()
    if path:
      try:
        with open(path, 'r') as file:
          return int(file.read().strip())
      except Exception:
        pass
  return 100

def supports_charge_limit():
  if device_utils.is_rog_ally_series() and rog_ally.supports_charge_limit():
    return True
  if device_utils.is_msi_claw_8_ex_ai() and msi_charge_threshold_path():
    return True
  return False

def set_charge_limit(limit):
  if not charge_limit_enabled():
    return

  if device_utils.is_rog_ally_series():
    return rog_ally.set_charge_limit(limit)
  if device_utils.is_msi_claw_8_ex_ai():
    path = msi_charge_threshold_path()
    if not path:
      # Documented limitation: the EC does not expose a charge cap to Linux.
      return False
    try:
      value = max(MSI_CHARGE_LIMIT_MIN, min(MSI_CHARGE_LIMIT_MAX, int(limit)))
      with open(path, 'w') as file:
        file.write(str(value))
      return True
    except Exception:
      return False
  return False

def get_expected_charge_limit():
  # CHARGE_LIMIT = 'chargeLimit'
  return get_nested_setting('advanced.chargeLimit')

def charge_limit_enabled():
  return get_nested_setting('advanced.enableChargeLimit')

def initialize_charge_limit():
  if supports_charge_limit() and charge_limit_enabled():
    current_limit = get_current_charge_limit()
    expected_limit = get_expected_charge_limit()

    if isinstance(expected_limit, int) and current_limit != expected_limit:
      set_charge_limit(expected_limit)