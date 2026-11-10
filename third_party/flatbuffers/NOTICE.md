# FlatBuffers test dependency

`reflection.fbs` is from `google/flatbuffers`, tag `v25.12.19`:
https://github.com/google/flatbuffers/blob/v25.12.19/reflection/reflection.fbs

It is used only by the integration tests, letting the official `flatc` decode
and compare binary schemas independently of our BFBS reader. The upstream
Apache 2.0 license is included in `LICENSE.txt` (upstream filename `LICENSE`).

The optional executable is downloaded from the official release by
`tools/bootstrap_flatc.py`, which pins the URL and verifies its SHA-256.
The executable is not part of the source tree.
