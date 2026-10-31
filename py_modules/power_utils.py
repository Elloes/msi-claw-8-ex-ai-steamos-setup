import os
import decky_plugin
import advanced_options
import plugin_timeout
from enum import Enum
import cpu_utils
import device_utils

class PowerGovernorOptions(Enum):
  POWER_SAVE = 'powersave'
  BALANCED = 'schedutil'
  PERFORMANCE = 'performance'

class EppOptions(Enum):
  PERFORMANCE = 'performance'
  BALANCE_PERFORMANCE = 'balance_performance'
  BALANCE_POWER = 'balance_power'
  POWER_SAVE = 'power'

# MSI Claw 8 EX AI+ (CG3EM) EPP guidance.
#
# The Arc B390 (Xe3) shares one 8-35 W package budget with the 14 Panther Lake
# cores. For a handheld the useful default is balance_power, not balance_perf:
# it lets the iGPU keep its share at low TDPs (8-15 W) where the Xe3 cores are
# the bottleneck. performance is only worth it for CPU-bound titles at 25 W+.
# These values are surfaced in the UI; the user can still pick any option the
# kernel exposes. On battery, powersave + power EPP gives the longest runtime.
MSI_CLAW_RECOMMENDED_EPP = {
  'intel_pstate': EppOptions.BALANCE_POWER.value,
  'intel_cpufreq': None,  # intel_cpufreq has no EPP attribute
  'amd-pstate-epp': EppOptions.BALANCE_POWER.value,
}

def get_recommended_epp(scaling_driver):
  """Recommended EPP for this device, or None when the driver has no EPP."""
  if device_utils.is_msi_claw_8_ex_ai():
    return MSI_CLAW_RECOMMENDED_EPP.get(scaling_driver)
  return RECOMMENDED_DEFAULTS.get(scaling_driver, {}).get('epp')

# if manual CPU controls are disabled by the end user, these values are used by default instead
DEFAULT_CPU_PROFILE = {
  "cpuBoost": False,
  "smt": True,
  "powerControls": {
      "intel_cpufreq": {
        "powerGovernor": PowerGovernorOptions.POWER_SAVE.value
      },
      "intel_pstate": {
          "epp": EppOptions.BALANCE_POWER.value,
          "powerGovernor": PowerGovernorOptions.POWER_SAVE.value
      },
      "amd-pstate-epp": {
          "epp": EppOptions.BALANCE_POWER.value,
          "powerGovernor": PowerGovernorOptions.POWER_SAVE.value
      },
      "amd-pstate": {
          "powerGovernor": PowerGovernorOptions.POWER_SAVE.value
      },
      "acpi-cpufreq": {
          "powerGovernor": PowerGovernorOptions.POWER_SAVE.value
      }
  }
}

# these are used when the user enables manual CPU controls
RECOMMENDED_DEFAULTS = {
  "intel_cpufreq": {
    "powerGovernor": PowerGovernorOptions.POWER_SAVE.value
  },
  'intel_pstate': {
    'epp': EppOptions.BALANCE_POWER.value,
    'powerGovernor': PowerGovernorOptions.POWER_SAVE.value
  },
  'amd-pstate-epp': {
    'epp': EppOptions.BALANCE_POWER.value,
    'powerGovernor': PowerGovernorOptions.POWER_SAVE.value
  },
  'amd-pstate': {
    'powerGovernor': PowerGovernorOptions.POWER_SAVE.value
  },
  'acpi-cpufreq': {
    'powerGovernor': PowerGovernorOptions.POWER_SAVE.value
  }
}

def set_power_governor(governor_option):
  try:
    option = PowerGovernorOptions(governor_option).value

    power_governor_devices = cpu_utils.get_power_governor_paths()

    if len(power_governor_devices) > 0:
      return write_command(option, power_governor_devices)
  except Exception as e:
    decky_plugin.logger.error(f'{__name__} error setting power governor {e}')

def get_available_epp_options():
  try:
    epp_option_paths = cpu_utils.get_epp_option_paths()
    if len(epp_option_paths) > 0:
      path = epp_option_paths[0]
      if os.path.exists(path):
        with open(path, 'r') as file:
          available_options = file.read().strip().split(' ') or []
          available_options.reverse()
          if available_options and 'default' in available_options:
            available_options.remove('default')
          file.close()
          # available_options.remove('default')
          return available_options
  except Exception as e:
    decky_plugin.logger.error(f'{__name__} error getting epp options {e}')

  return []

def get_available_governor_options():
  try:
    power_governor_option_paths = cpu_utils.get_power_governor_option_paths()
    if len(power_governor_option_paths) > 0:
      path = power_governor_option_paths[0]
      if os.path.exists(path):
        with open(path, 'r') as file:
          available_options = file.read().strip().split(' ') or []
          available_options.reverse()
          file.close()
          return available_options
  except Exception as e:
    decky_plugin.logger.error(f'{__name__} error getting power governor options {e}')

  return []

def set_epp(epp_option):
  try:
    if epp_option not in get_available_epp_options():
      return
    epp_devices = cpu_utils.get_epp_paths()
    if len(epp_devices) > 0:
      return write_command(epp_option, epp_devices)

  except Exception as e:
    decky_plugin.logger.error(f'{__name__} error setting epp {e}')

def write_command(command, paths):
  with plugin_timeout.time_limit(2):
    for p in paths:
      try:
        with open(p, 'w') as file:
          file.write(f'{command}')
          file.close()
      except OSError as e:
        if e.errno == 16:
          # Handle the [Errno 16] Device or resource busy error
          decky_plugin.logger.error(f'Error: {str(e)}. The device or resource is busy.')
        continue
      except Exception as e:
        decky_plugin.logger.error(e)
        continue

def power_controls_enabled():
  with plugin_timeout.time_limit(1):
    return advanced_options.get_setting(
      advanced_options.DefaultSettings.ENABLE_POWER_CONTROL.value
    )
