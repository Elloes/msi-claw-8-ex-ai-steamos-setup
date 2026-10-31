import os
import decky_plugin
import device_utils
from cpu_utils import INTEL_CPU_BOOST_PATH, get_online_cpus
from plugin_settings import get_saved_settings, set_setting

# Caps are ordered P-cores, E-cores, LP E-cores (base_frequency descending).
# Default set kept for the 3-class Panther Lake handheld this plugin was
# originally tuned on: 3.0 / 2.0 / 1.5 GHz.
SMART_BOOST_CAPS_KHZ = [3000000, 2000000, 1500000]

# MSI Claw 8 EX AI+ (Arc G3 Extreme, Panther Lake 18A, CG3EM):
#   2x Cougar Cove P-cores  up to 4.7 GHz
#   8x Darkmont E-cores     up to 3.4 GHz
#   4x Darkmont LP E-cores  up to 3.1 GHz
# "Smart" keeps the game's main thread on a fast P-core while stopping the
# E-cores from eating the Arc B390's share of the 8-35 W budget. The caps sit
# at roughly 70% of each class's maximum, leaving headroom for boost while
# staying well under the thermal ceiling of the Claw's 6-screw, rear-intake
# / top-exhaust chassis. These are starting values: measure per game and
# adjust here if a title is CPU-bound at 8-15 W.
MSI_CLAW_SMART_BOOST_CAPS_KHZ = [3400000, 2400000, 1800000]

UNCAPPED_KHZ = 9999999

def get_smart_boost_caps():
  """Return the cap set for this device (P, E, LP E-cores in kHz)."""
  if device_utils.is_msi_claw_8_ex_ai():
    return MSI_CLAW_SMART_BOOST_CAPS_KHZ
  return SMART_BOOST_CAPS_KHZ

SMART_CAPS_APPLIED_SETTING = 'smartBoostCapsApplied'

def cpufreq_path(cpu_num, attribute):
  return f'/sys/devices/system/cpu/cpu{cpu_num}/cpufreq/{attribute}'

def read_base_frequency(cpu_num):
  with open(cpufreq_path(cpu_num, 'base_frequency'), 'r') as file:
    return int(file.read().strip())

def get_cpu_classes():
  cpus_by_base_frequency = {}
  try:
    for cpu_num in get_online_cpus():
      cpus_by_base_frequency.setdefault(read_base_frequency(cpu_num), []).append(cpu_num)
  except Exception as e:
    decky_plugin.logger.error(f'{__name__} get_cpu_classes {e}')
    return []

  return [cpus_by_base_frequency[base] for base in sorted(cpus_by_base_frequency, reverse=True)]

def supports_smart_boost():
  # Smart boost needs exactly three base-frequency classes, which the Claw 8
  # EX AI+ provides (P, E and LP E-cores) just like the device this fork
  # started from. A 2-class or 4-class CPU falls back to the upstream toggle.
  return (
    device_utils.is_intel()
    and os.path.exists(INTEL_CPU_BOOST_PATH)
    and len(get_cpu_classes()) == len(get_smart_boost_caps())
  )

def write_max_freq(cpu_nums, khz):
  for cpu_num in cpu_nums:
    try:
      with open(cpufreq_path(cpu_num, 'scaling_max_freq'), 'w') as file:
        file.write(str(khz))
    except Exception as e:
      decky_plugin.logger.error(f'{__name__} write_max_freq cpu{cpu_num} {e}')

def smart_caps_applied():
  return bool(get_saved_settings().get(SMART_CAPS_APPLIED_SETTING, False))

def set_smart_boost_caps(enabled):
  caps_applied = smart_caps_applied()
  cpu_classes = get_cpu_classes()

  if enabled:
    for cpu_nums, khz in zip(cpu_classes, get_smart_boost_caps()):
      write_max_freq(cpu_nums, khz)
  elif caps_applied:
    for cpu_nums in cpu_classes:
      write_max_freq(cpu_nums, UNCAPPED_KHZ)

  if enabled != caps_applied:
    set_setting(SMART_CAPS_APPLIED_SETTING, enabled)
