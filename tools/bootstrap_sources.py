"""Fetch the pinned, hash-verified official FlatBuffers source (Python stdlib)."""
import argparse
import hashlib
import io
from pathlib import Path, PurePosixPath
import urllib.request
import zipfile

URL = 'https://codeload.github.com/google/flatbuffers/zip/refs/tags/v25.12.19'
SHA256 = 'f5d4636bfc4d30c622c9ad238ce947848c2b90b10aecd387dc62cdee2584359b'

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive',type=Path,help='Use an already downloaded archive')
    parser.add_argument('--destination',type=Path,default=Path(__file__).resolve().parents[1]/'.tools')
    args=parser.parse_args()
    data=args.archive.read_bytes() if args.archive else urllib.request.urlopen(URL,timeout=60).read()
    if hashlib.sha256(data).hexdigest()!=SHA256:
        raise SystemExit('FlatBuffers source archive checksum mismatch')
    destination=args.destination.resolve()
    target=destination/'flatbuffers-25.12.19'
    if target.exists():
        raise SystemExit(f'Destination already exists: {target}')
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        for entry in archive.infolist():
            path=PurePosixPath(entry.filename)
            if path.is_absolute() or '..' in path.parts or not path.parts or path.parts[0]!=target.name:
                raise SystemExit('Unexpected source archive path')
        archive.extractall(destination)
    print(target)

if __name__=='__main__':
    main()
