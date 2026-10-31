"""MSI Claw 8 EX AI+ (Panther Lake / Arc B390 "Xe3", model CG3EM) support.

This module is the MSI counterpart of the per-vendor modules in this package
(``rog_ally.py``, ``lenovo.py``, ``steam_deck.py``). It holds what is genuinely
device specific for the Claw 8 EX AI+. Anything MSI does not expose to Linux is
implemented as an explicit, documented placeholder instead of a guess that
silently fails.

WHAT IS IMPLEMENTED HERE
* Battery reporting: percentage, status, energy_now/full, power draw and cycle
  count from ``/sys/class/power_supply``. The Claw has an 80 Wh 4-cell
  Li-polymer pack; nothing in the reporting is size dependent.
* Capability probing for fan and RGB so the UI can hide controls the EC does not
  expose.

WHAT IS NOT IMPLEMENTED, AND WHY
* FAN CURVES. The fan is driven by the embedded controller and configured in
  MSI Center on Windows. Whether the EC exposes ``pwm1``/``pwm1_enable`` through
  ``/sys/class/hwmon`` on this BIOS is unverified. ``fan_pwm_paths()`` probes for
  it; when nothing is found ``supports_fan_control()`` returns False and the
  plugin leaves the fan to the EC. A blind pwm write on an unknown EC is how
  handhelds get cooked, so no path is guessed. If a writable ``pwm1`` is found on
  real hardware, ``set_fan_duty()`` is already safe to drive a curve from.
* RGB. The Claw has RGB on the ABXY buttons and the analog-stick rings. MSI
  Center is the documented control surface. On Linux this normally appears as
  ``/sys/class/leds/*:rgb:*`` (multicolor class) or through a vendor HID driver.
  ``rgb_led_paths()`` probes the LED class; if empty, lighting must be set in MSI
  Center and this module returns False rather than writing unknown HID reports.
* BYPASS CHARGING. MSI Center's bypass mode runs from AC without charging the
  pack. There is no generic Linux attribute for it. Some MSI laptops expose it
  through ACPI-WMI, but the Claw's WMI GUIDs are not confirmed, so
  ``supports_bypass_charging()`` returns False and the README documents it.
  Charge *limits* are handled in ``charge_limit.py`` via the power supply class.
* MSI CENTER INTEGRATION. MSI Center / MSI Center M are Windows applications;
  there is no Linux service to call. Everything the plugin needs from MSI Center
  is either a sysfs/EC value (handled above) or unavailable. The plugin replaces
  "ask MSI Center" calls with direct sysfs access and documents the gaps.
  ``get_msi_center_status()`` reports what was found for the UI and bug reports.
"""

import glob
import os

import decky_plugin

# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------
MSI_VENDOR = "Micro-Star International"      # /sys/class/dmi/id/sys_vendor
MSI_PRODUCT_SUBSTRINGS = [
  "Claw 8 EX AI+",
  "Claw 8 EX AI",
  "CG3EM",
]
MSI_MODEL = "CG3EM"

# 80 Wh 4-cell Li-polymer. Used for runtime estimates only; the kernel reports
# the real values, so a different pack revision still reports correctly.
BATTERY_WH = 80.0
BATTERY_CELLS = 4

# ---------------------------------------------------------------------------
# Fan / thermal
# ---------------------------------------------------------------------------
# The Claw's cooling is rear intake, top exhaust, with six screws on the back.
# The EC owns the curve. These probes only report what Linux can actually see.
FAN_HWMON_NAME_HINTS = ["msi", "ec", "claw", "panther"]
FAN_PWM_ATTRIBUTES = ["pwm1", "pwm2"]
FAN_PWM_ENABLE_ATTRIBUTES = ["pwm1_enable", "pwm2_enable"]

def fan_hwmon_paths():
  """Return hwmon directories whose name looks like the Claw's EC."""
  paths = []
  for hwmon in glob.glob('/sys/class/hwmon/hwmon*'):
    try:
      with open(os.path.join(hwmon, 'name'), 'r') as file:
        name = file.read().strip().lower()
    except Exception:
      continue
    if any(hint in name for hint in FAN_HWMON_NAME_HINTS):
      paths.append(hwmon)
  return paths

def fan_pwm_paths():
  """Return writable pwmN files exposed by the EC, if any."""
  writable = []
  for hwmon in fan_hwmon_paths():
    for attribute in FAN_PWM_ATTRIBUTES:
      path = os.path.join(hwmon, attribute)
      try:
        if os.path.exists(path) and os.access(path, os.W_OK):
          writable.append(path)
      except Exception:
        continue
  return writable

def supports_fan_control():
  """True only when the EC exposes a writable PWM channel.

  On shipping Claw 8 EX AI+ firmware this is expected to be False; the fan
  curve lives in the EC and is configured through MSI Center on Windows.
  """
  return len(fan_pwm_paths()) > 0

def set_fan_duty(duty):
  """Set a raw fan duty (0-255) on every writable PWM channel.

  Only used when supports_fan_control() is True. A real fan curve for the
  Claw's rear-intake/top-exhaust layout would call this from a curve loop;
  until the EC interface is confirmed, the plugin leaves the fan alone.
  """
  duty = max(0, min(255, int(duty)))
  written = False
  for hwmon in fan_hwmon_paths():
    for attribute in FAN_PWM_ENABLE_ATTRIBUTES:
      path = os.path.join(hwmon, attribute)
      try:
        if os.path.exists(path) and os.access(path, os.W_OK):
          # 1 = manual mode on the standard hwmon interface
          with open(path, 'w') as file:
            file.write('1')
      except Exception as e:
        decky_plugin.logger.error(f'{__name__} set_fan_duty enable {e}')
  for path in fan_pwm_paths():
    try:
      with open(path, 'w') as file:
        file.write(str(duty))
      written = True
    except Exception as e:
      decky_plugin.logger.error(f'{__name__} set_fan_duty {path}: {e}')
  return written

# ---------------------------------------------------------------------------
# RGB / lighting
# ---------------------------------------------------------------------------
# Expected zones on the Claw 8 EX AI+: ABXY button lighting and the two
# analog-stick rings. The original fork exposed three zones through a vendor
# hid driver; the Claw does not use that driver, so this probe looks at the
# standard multicolor LED class instead.
RGB_ZONE_HINTS = ["rgb", "msi", "claw", "abxy", "stick"]

def rgb_led_paths():
  """Return multicolor LED class directories that could be Claw lighting."""
  paths = []
  for led in glob.glob('/sys/class/leds/*'):
    name = os.path.basename(led).lower()
    if any(hint in name for hint in RGB_ZONE_HINTS):
      paths.append(led)
  return paths

def supports_rgb_control():
  """True only when a multicolor LED zone is writable from Linux."""
  for led in rgb_led_paths():
    intensity = os.path.join(led, 'multi_intensity')
    if os.path.exists(intensity) and os.access(intensity, os.W_OK):
      return True
  return False

def set_rgb_intensity(zone, red, green, blue):
  """Set one zone's RGB intensity when the LED class exposes it.

  ``zone`` is a directory returned by rgb_led_paths(). MSI Center owns these
  LEDs on firmware that does not expose them, in which case this returns False.
  """
  path = os.path.join(zone, 'multi_intensity')
  try:
    if not (os.path.exists(path) and os.access(path, os.W_OK)):
      return False
    with open(path, 'w') as file:
      file.write(f'{int(red)} {int(green)} {int(blue)}')
    return True
  except Exception as e:
    decky_plugin.logger.error(f'{__name__} set_rgb_intensity {e}')
    return False

# ---------------------------------------------------------------------------
# Charging
# ---------------------------------------------------------------------------
def supports_bypass_charging():
  """Always False until an MSI Claw ACPI-WMI bypass interface is confirmed.

  MSI Center's bypass mode has no generic Linux attribute. Do not invent one:
  writing an unknown EC/WMI call can leave the pack in an undefined state.
  See the module docstring and the README "Known limitations" section.
  """
  return False

def bypass_charging_status():
  """Placeholder for the bypass-charging state. See supports_bypass_charging()."""
  return None

# ---------------------------------------------------------------------------
# Battery reporting (80 Wh 4-cell Li-polymer)
# ---------------------------------------------------------------------------
def battery_path():
  """Return the battery's power_supply directory, or None."""
  for candidate in ('/sys/class/power_supply/BAT1', '/sys/class/power_supply/BAT0'):
    if os.path.isdir(candidate):
      return candidate
  for path in glob.glob('/sys/class/power_supply/BAT*'):
    return path
  return None

def _read_int(path):
  try:
    with open(path, 'r') as file:
      return int(file.read().strip())
  except Exception:
    return None

def _read_str(path):
  try:
    with open(path, 'r') as file:
      return file.read().strip()
  except Exception:
    return None

def get_battery_info():
  """Battery percentage and health data for the UI / bug reports.

  ``energy_now`` and ``energy_full`` are in microwatt-hours on this platform and
  ``capacity`` is the percentage the firmware reports. ``cycle_count`` is
  present on most MSI packs; when absent it is returned as None.
  """
  path = battery_path()
  if not path:
    return None

  energy_now = _read_int(os.path.join(path, 'energy_now'))
  energy_full = _read_int(os.path.join(path, 'energy_full'))
  energy_full_design = _read_int(os.path.join(path, 'energy_full_design'))
  power_now = _read_int(os.path.join(path, 'power_now'))

  info = {
    'path': path,
    'capacity': _read_int(os.path.join(path, 'capacity')),
    'status': _read_str(os.path.join(path, 'status')),
    'energy_now_wh': round(energy_now / 1_000_000, 2) if energy_now else None,
    'energy_full_wh': round(energy_full / 1_000_000, 2) if energy_full else None,
    'energy_full_design_wh': round(energy_full_design / 1_000_000, 2) if energy_full_design else None,
    'power_now_w': round(power_now / 1_000_000, 2) if power_now else None,
    'cycle_count': _read_int(os.path.join(path, 'cycle_count')),
    'pack_wh_nominal': BATTERY_WH,
    'pack_cells': BATTERY_CELLS,
  }

  if energy_full and energy_full_design:
    info['health_percent'] = round(100.0 * energy_full / energy_full_design, 1)

  return info

# ---------------------------------------------------------------------------
# MSI Center replacement summary
# ---------------------------------------------------------------------------
def get_msi_center_status():
  """Report which MSI Center features have a Linux equivalent.

  MSI Center / MSI Center M are Windows-only. This dict tells the UI (and bug
  reports) what the plugin can do directly and what still needs MSI Center on a
  Windows install. Unknown is reported as False on purpose.
  """
  return {
    'msiCenterAvailable': False,          # no Linux service to call
    'fanControlAvailable': supports_fan_control(),
    'rgbControlAvailable': supports_rgb_control(),
    'chargeLimitAvailable': _charge_limit_available(),
    'bypassChargingAvailable': supports_bypass_charging(),
    'batteryReportingAvailable': battery_path() is not None,
    'tdpControlAvailable': os.path.exists(
      '/sys/devices/virtual/powercap/intel-rapl-mmio/intel-rapl-mmio:0/constraint_0_power_limit_uw'
    ),
    'workaround': (
      'Set fan curves, RGB and bypass charging in MSI Center on Windows; '
      'TDP, EPP, charge limit and battery reporting are handled by this plugin '
      'through sysfs while running SteamOS.'
    ),
  }

def _charge_limit_available():
  # Imported lazily to avoid a circular import (charge_limit imports devices).
  try:
    import charge_limit
    return charge_limit.supports_charge_limit()
  except Exception:
    return False

def init():
  """Log the detected MSI capabilities once at plugin start."""
  try:
    status = get_msi_center_status()
    battery = get_battery_info()
    decky_plugin.logger.info(f'{__name__} MSI Claw 8 EX AI+ capabilities: {status}')
    if battery:
      decky_plugin.logger.info(f'{__name__} battery: {battery}')
  except Exception as e:
    decky_plugin.logger.error(f'{__name__} init {e}')

