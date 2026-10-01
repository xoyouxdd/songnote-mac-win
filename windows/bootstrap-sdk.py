"""Install the pinned Microsoft SDK inside this repository, with SHA512 verification."""
import hashlib
import json
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VERSION = json.loads((ROOT / "windows" / "global.json").read_text(encoding="utf-8"))["sdk"]["version"]
with urllib.request.urlopen("https://builds.dotnet.microsoft.com/dotnet/release-metadata/10.0/releases.json", timeout=30) as response:
    metadata = json.load(response)
sdk = next(s for release in metadata["releases"] for s in release.get("sdks", []) if s["version"] == VERSION)
asset = next(f for f in sdk["files"] if f["rid"] == "win-x64" and f["name"].endswith(".zip"))
archive = ROOT / "build" / "tooling" / f"dotnet-sdk-{VERSION}-win-x64.zip"
archive.parent.mkdir(parents=True, exist_ok=True)

def valid():
    if not archive.exists():
        return False
    with archive.open("rb") as stream:
        return hashlib.file_digest(stream, "sha512").hexdigest().lower() == asset["hash"].lower()

if not valid():
    print(f"Downloading Microsoft .NET SDK {VERSION} to build/tooling", flush=True)
    urllib.request.urlretrieve(asset["url"], archive)
if not valid():
    raise SystemExit("SDK SHA512 mismatch; archive will not be extracted")
target = ROOT / "build" / "dotnet"
with zipfile.ZipFile(archive) as package:
    if any(not (target / name).resolve().is_relative_to(target.resolve()) for name in package.namelist()):
        raise SystemExit("SDK archive contains an unsafe path")
    package.extractall(target)
print(f"SDK_SHA512_OK: {target}")
