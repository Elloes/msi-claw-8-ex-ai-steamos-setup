from enum import Enum
import os
import plugin_timeout
import decky_plugin
import re

class Devices(Enum):
  LEGION_GO = "83E1"
  LEGION_GO_2_Z2_EXTREME = "83N0"
  LEGION_GO_2_Z2 = "83N1"
  LEGION_GO_S_Z2_GO = "83L3"
  LEGION_GO_S_Z1_EXTREME = "83N6"
  ROG_ALLY = "ROG Ally RC71"
  ROG_ALLY_X = "ROG Ally X RC72"
  ROG_XBOX_ALLY="ROG Xbox Ally"
  MINISFORUM_V3 = "V3"
  GPD_WM2 = "G1619-04"
  GPD_WIN4 = "G1618-04"
  ASUS_FLOW_Z13 = "ROG Flow Z13 GZ302EA_GZ302EA"
  STEAM_DECK_LCD = "Jupiter"
  STEAM_DECK_OLED = "Galileo"
  # MSI Claw 8 AI+ (Lunar Lake / Arc 140V). Kept for upstream compatibility.
  MSI_CLAW_8_AI ="Claw 8 AI+ A2VM"
  # MSI Claw 8 EX AI+ (Panther Lake / Arc B390 "Xe3"), project model CG3EM.
  # DMI product_name on shipping units is not confirmed yet, so detection
  # matches several substrings. Override with the env var
  # MSI_CLAW_DMI_SUBSTRING if a retail unit reports something else.
  MSI_CLAW_8_EX_AI = "Claw 8 EX AI+"
  MSI_CLAW_8_EX_AI_MODEL = "CG3EM"

class CpuVendors(Enum):
  INTEL = "GenuineIntel"
  AMD = "AuthenticAMD"

class CpuModels(Enum):
  STRIX_HALO = "AI MAX+ 395 w/ Radeon 8060S"

CPU_VENDOR = None
DEVICE_NAME = None
CPU_MODEL = None

def get_cpu_model():
  global CPU_MODEL

  if not CPU_MODEL:
    try:
      with open("/proc/cpuinfo", "r") as file:
          cpuinfo = file.read().strip()
          file.close()

          pattern = r'model name\s*:\s*(.*)'
          match = re.search(pattern, cpuinfo)

          if match:
              vendor_id = match.group(1)
              CPU_MODEL = vendor_id.strip()
              decky_plugin.logger.info(f"cpu model: {CPU_MODEL}")
          else:
              decky_plugin.logger.error("No CPU model found")
    except Exception as e:
      decky_plugin.logger.error(f'{__name__} error while trying to read cpu model')
  return CPU_MODEL

def get_cpu_manufacturer():
  global CPU_VENDOR

  if not CPU_VENDOR:
    try:
      with open("/proc/cpuinfo", "r") as file:
          cpuinfo = file.read().strip()
          file.close()

          pattern = r'vendor_id\s*:\s*(\S+)'

          match = re.search(pattern, cpuinfo)

          if match:
              vendor_id = match.group(1)
              CPU_VENDOR = vendor_id.strip()
              decky_plugin.logger.info(f"cpu vendor: {CPU_VENDOR}")
          else:
              decky_plugin.logger.error("No CPU vendor_id found")          
    except Exception as e:
      decky_plugin.logger.error(f'{__name__} error while trying to read cpu manufacturer')
  return CPU_VENDOR

def is_intel():
  vendor = get_cpu_manufacturer()

  return vendor == CpuVendors.INTEL.value

def get_device_name():
  global DEVICE_NAME

  if not DEVICE_NAME:
    try:
      with plugin_timeout.time_limit(2):
        with open("/sys/devices/virtual/dmi/id/product_name", "r") as file:
          device_name = file.read().strip()
          file.close()

          DEVICE_NAME = device_name
    except Exception as e:
      decky_plugin.logger.error(f'{__name__} error while trying to read device name')
  return DEVICE_NAME or ''

def is_msi_claw_ai():
  """MSI Claw 8 AI+ (Lunar Lake, A2VM)."""
  device_name = get_device_name()

  if Devices.MSI_CLAW_8_AI.value in device_name:
    return True
  return False

def msi_claw_dmi_substrings():
  """DMI product_name substrings that identify a Claw 8 EX AI+ (CG3EM).

  The first three are the strings this project expects. The env override
  exists because the retail DMI string has not been verified on hardware
  yet; run `cat /sys/devices/virtual/dmi/id/product_name` on the device
  and set MSI_CLAW_DMI_SUBSTRING if it differs.
  """
  substrings = [
    Devices.MSI_CLAW_8_EX_AI.value,          # "Claw 8 EX AI+"
    Devices.MSI_CLAW_8_EX_AI_MODEL.value,    # "CG3EM"
    "Claw 8 EX AI",                          # variant without the plus
  ]
  override = os.environ.get('MSI_CLAW_DMI_SUBSTRING', '').strip()
  if override:
    substrings.insert(0, override)
  return substrings

def is_msi_claw_8_ex_ai():
  """True on the MSI Claw 8 EX AI+ (Panther Lake, CG3EM)."""
  device_name = get_device_name()
  if not device_name:
    return False
  return any(sub in device_name for sub in msi_claw_dmi_substrings())

def is_msi_claw_series():
  """Any MSI Claw handheld this plugin knows about."""
  return is_msi_claw_ai() or is_msi_claw_8_ex_ai()

def is_rog_ally_x():
  device_name = get_device_name()

  if Devices.ROG_ALLY_X.value in device_name:
    return True
  return False

def is_rog_xbox_ally():
  device_name = get_device_name()

  if Devices.ROG_XBOX_ALLY.value in device_name:
    return True
  return False

def is_rog_ally():
  device_name = get_device_name()

  if Devices.ROG_ALLY.value in device_name:
    return True
  return False

def is_rog_ally_series():
  return is_rog_ally() or is_rog_ally_x() or is_rog_xbox_ally()

def is_legion_go():
  device_name = get_device_name()

  if device_name == Devices.LEGION_GO.value:
    return True
  if device_name == Devices.LEGION_GO_2_Z2_EXTREME.value:
    return True
  if device_name == Devices.LEGION_GO_2_Z2.value:
    return True
  if device_name == Devices.LEGION_GO_S_Z2_GO.value:
    return True
  if device_name == Devices.LEGION_GO_S_Z1_EXTREME.value:
    return True
  return False

def is_steam_deck():
  device_name = get_device_name()

  if Devices.STEAM_DECK_LCD.value in device_name or Devices.STEAM_DECK_OLED.value in device_name:
    return True
  return False

def is_amd_strix_halo():
  cpu_model = get_cpu_model()

  if CpuModels.STRIX_HALO.value in cpu_model:
    return True
  return False