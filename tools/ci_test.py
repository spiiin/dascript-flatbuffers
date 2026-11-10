"""Build the adapter and execute both suites against pinned local dependencies."""
from pathlib import Path
import os
import subprocess
import sys

root=Path(__file__).resolve().parents[1]
windows=os.name=='nt'
das=root/'.tools/daScript/bin'/('Release/daslang.exe' if windows else 'daslang')
source=root/'.tools/flatbuffers-25.12.19'
build=root/'build/cpp'
def run(*args):
    subprocess.run([str(a) for a in args],cwd=root,check=True)

run('cmake','-S',root/'integration','-B',build,'-DCMAKE_BUILD_TYPE=Release',
    f'-DFLATBUFFERS_SOURCE_DIR={source.as_posix()}',f'-DDASLANG_EXECUTABLE={das.as_posix()}')
run('cmake','--build',build,'--config','Release','--parallel','2')
flatc=build/'flatbuffers'/('Release/flatc.exe' if windows else 'flatc')
verifier=build/('Release/fb_verify_cpp.exe' if windows else 'fb_verify_cpp')
for suite in ['run_tests.py','run_extended.py']:
    run(sys.executable,root/'tests'/suite,'--daslang',das,'--flatc',flatc,
        '--flatc-das',flatc,'--cpp-verifier',verifier,'--flatbuffers-source',source)
