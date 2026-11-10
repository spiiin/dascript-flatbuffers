# daScript FlatBuffers

FlatBuffers serialization for [daScript](https://github.com/GaijinEntertainment/daScript). Write annotated daScript types or generate them from a `.fbs` schema. Both modes use a shared schema IR, AST macros, builder, verifier, and view API.

## Quick start

Run commands from the repository root with `flatc` and `daslang` on `PATH`. On Windows, `python tools/bootstrap_flatc.py` installs a pinned `flatc.exe` under `.tools/`; add that directory to `PATH` or use the executable path directly.

Define a root table in daScript:

```das
options gen2
require ../src/annotations.das

[fb_table]
struct Item {
    @fb_id=0
    value:int=7
}

[fb_table(root=true,identifier="DEMO")]
struct Root {
    @fb_id=0
    number:Option<int>
    @fb_id=1
    text:Option<string>
    @fb_id=2
    item:Option<Item>
}
```

The macro generates `fb_pack_Root`, `fb_unpack_Root`, `fb_verify_Root`, `fb_view_Root`, `fb_schema_Root`, and schema IR helpers. `none` omits a field; `some(value)` writes it even when it equals a default. See `examples/` for runnable models.

To generate daScript from a FlatBuffers schema, compile it to BFBS and run the source generator:

```powershell
mkdir generated
flatc -b --schema --bfbs-builtins --bfbs-comments -o generated tests/record.fbs
daslang -no-module-cache -no-dynamic-modules tools/generate.das -- generated/record.bfbs generated/record_generated.das generated/record_normalized.fbs
```

Generated modules import `../src/annotations.das` by default. The optional fourth script argument changes that import path.

## Supported schemas

- Tables, fixed structs, enums, unions and union vectors, recursive tables, and nested FlatBuffers.
- Scalars, strings, vectors, fixed arrays in structs, optional scalars, and nullable reference fields.
- Required and deprecated fields, explicit IDs, namespaces, file identifiers, defaults, keys, and alignment.
- Supported `offset64` and `vector64` combinations, size-prefixed buffers, custom attributes, documentation, includes, and RPC service metadata.

Use `[fb_table]`, `[fb_struct]`, and `[fb_enum]` in code-first mode. `Option<T>` models presence for generated nullable strings, vectors, structs, and tables. `FBRef<T>` models recursive table references as a tree. The generated schema is available through `fb_schema_Type()`; writing it to a file is an explicit runtime operation.

## Reading and validating buffers

```das
let schema <- fb_schema_ir_Root()
verify(fb_verify_Root(bytes))
let root=fb_view_Root(bytes)
let field=fb_view_field(bytes,schema,root,0)
let number=fb_view_scalar(bytes,field,0)
```

Views refer to offsets in the original buffer. Keep that buffer unchanged while using a view. Verify untrusted data before traversal. `FBVerifyOptions` configures depth, object-count, UTF-8, and alignment checks.

## flatc adapter and tests

The optional C++ adapter adds `--dascript` to a locally built official `flatc`; it does not modify upstream sources. Development requires Python 3, CMake, C++17, daScript, and FlatBuffers 25.12.19. Bootstrap scripts download pinned, SHA-256-verified dependencies.

```powershell
python tools/bootstrap_sources.py
cmake -S integration -B build/cpp -DFLATBUFFERS_SOURCE_DIR=.tools/flatbuffers-25.12.19 -DDASLANG_EXECUTABLE=/path/to/daslang
cmake --build build/cpp --config Release
/path/to/built/flatc --dascript -o generated tests/record.fbs
```

Run the compatibility suites:

```powershell
python tests/run_tests.py --daslang daslang --flatc /path/to/flatc
python tests/run_extended.py --daslang daslang --flatc /path/to/flatc --cpp-verifier /path/to/fb_verify_cpp --flatc-das /path/to/built/flatc --flatbuffers-source .tools/flatbuffers-25.12.19
```

The suites compare generated schemas and buffers with official `flatc` and C++ readers, exercise both input modes, and mutate buffers to test validation. `.github/workflows/compatibility.yml` runs them on Windows and Linux.

## Limitations

- Native arrays use `int` indexing, so buffers remain below 2 GiB. Huge-buffer streaming is unavailable.
- `FBRef<T>` does not preserve shared identity or cycles. Fixed arrays are one-dimensional.
- Nonempty string or vector schema defaults are unsupported. Unknown BFBS advanced-feature bits are rejected.
- The tested `flatc` version loses `ulong` schema defaults above `INT64_MAX` in BFBS. Full-range `uint64` field values are supported.
- RPC helpers require a caller-provided transport. No network runtime or gRPC server generator is included.
- Views are generic and schema-driven; typed accessors and AOT benchmarks are not provided.

See the official FlatBuffers [schema guide](https://flatbuffers.dev/schema/) and [wire format guide](https://flatbuffers.dev/internals/).

## License

MIT. See [LICENSE](LICENSE). The bundled `third_party/flatbuffers` files retain their own license and notice.
