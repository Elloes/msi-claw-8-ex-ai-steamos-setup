import os
import stat
import decky_plugin
import subprocess
import urllib.request
import json
import ssl
import shutil
from plugin_settings import settings_path

# Set these two to the GitHub account/repository that hosts this fork before
# publishing a release. The bulk rename that produced this fork turned the
# original URL into a repository that does not exist, so the OTA updater would
# 404 until these are filled in. Keeping them as constants means there is only
# one place to change.
GITHUB_OWNER = "Elloes"
GITHUB_REPO = "msi-claw-8-ex-ai-steamos-setup"

API_URL = f"https://api.github.com/repos/{GITHUB_OWNER}/{GITHUB_REPO}/releases/latest"

RELEASE_ASSET_NAME = "simpledeckytdp-msi-claw.zip"

def restart_decky_loader():
  env = os.environ.copy()
  env["LD_LIBRARY_PATH"] = ""
  cmd = f'echo "sudo systemctl restart plugin_loader.service" | sh'

  return subprocess.run(cmd, shell=True, check=True, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)

def recursive_chmod(path, perms):
  for dirpath, dirnames, filenames in os.walk(path):
    current_perms = os.stat(dirpath).st_mode
    os.chmod(dirpath, current_perms | perms)
    for filename in filenames:
      os.chmod(os.path.join(dirpath, filename), current_perms | perms)

def download_latest_build():
  # ssl._create_default_https_context = ssl._create_unverified_context
  gcontext = ssl.SSLContext()

  response = urllib.request.urlopen(API_URL, context=gcontext)
  json_data = json.load(response)

  download_url = next(
    asset.get("browser_download_url")
    for asset in json_data.get("assets")
    if asset.get("name") == RELEASE_ASSET_NAME
  )

  file_path = "/tmp/SimpleDeckyTDP.tar.gz"

  if download_url.endswith(".zip"):
    file_path = "/tmp/SimpleDeckyTDP.zip"

  with urllib.request.urlopen(download_url, context=gcontext) as response, open(file_path, 'wb') as output_file:
    output_file.write(response.read())
    output_file.close()

  return file_path

def ota_update():
  downloaded_filepath = download_latest_build()

  if os.path.exists(downloaded_filepath):
    plugin_dir = decky_plugin.DECKY_PLUGIN_DIR

    try:
      recursive_chmod(plugin_dir, stat.S_IWUSR)

      shutil.rmtree(plugin_dir)
    except Exception as e:
      decky_plugin.logger.error(f'ota error during removal of old plugin {e}')

    try:
      shutil.unpack_archive(downloaded_filepath, os.path.dirname(plugin_dir))
      os.remove(downloaded_filepath)
    except Exception as e:
      decky_plugin.logger.error(f'error during install {e}')

    restart_decky_loader()

    return result

def get_latest_version():
  gcontext = ssl.SSLContext()

  response = urllib.request.urlopen(API_URL, context=gcontext)
  json_data = json.load(response)

  tag = json_data.get("tag_name")
  # if tag is a v* tag, remove the v
  if tag.startswith("v"):
      tag = tag[1:]
  return tag

def reset_settings():
  try:
    settings_file = settings_path
    os.remove(settings_file)

    decky_plugin.logger.info(f'removed settings file at {settings_file}')

    restart_decky_loader()

    return result
  except Exception as e:
    decky_plugin.logger.error(f'error during plugin settings reset {e}')
