import base64
import subprocess
import sys

script = "$ProgressPreference='SilentlyContinue'; [Console]::OutputEncoding=[System.Text.Encoding]::UTF8;\n" + sys.stdin.read()
encoded = base64.b64encode(script.encode('utf-16le')).decode()
result = subprocess.run(['ssh', '-S', '/tmp/sticky-notes-ssh-20261001.sock',
                'Administrator@124.220.229.9',
                'powershell -NoProfile -EncodedCommand ' + encoded])
sys.exit(result.returncode)
