"""Install a pinned official Windows flatc binary into this project's .tools/."""
from pathlib import Path
import hashlib
import io
import os
import urllib.request
import zipfile

URL = ('https://github.com/google/flatbuffers/releases/download/'
       'v25.12.19-2026-02-06-03fffb2/Windows.flatc.binary.zip')
SHA256 = '68d51916873a3dbdaf7997ddfbbbfd6472b5907ffc62ccc9a88d146bbc0db87d'

if __name__ == '__main__':
    if os.name != 'nt':
        raise SystemExit('This installer is Windows-only. Install flatc and pass --flatc to the tests.')
    archive = urllib.request.urlopen(URL, timeout=60).read()
    if hashlib.sha256(archive).hexdigest() != SHA256:
        raise SystemExit('flatc archive checksum mismatch')
    with zipfile.ZipFile(io.BytesIO(archive)) as z:
        binary = z.read('flatc.exe')
    target = Path(__file__).resolve().parents[1] / '.tools/flatc.exe'
    target.parent.mkdir(exist_ok=True)
    target.write_bytes(binary)
    print(target)
