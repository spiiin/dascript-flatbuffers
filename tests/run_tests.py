"""Integration tests against the real flatc executable. Python stdlib only."""
from __future__ import annotations
import argparse
import json
import math
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--daslang', default=os.environ.get('DASLANG', 'daslang'))
parser.add_argument('--flatc', default=os.environ.get('FLATC', str(ROOT / '.tools/flatc.exe')))
parser.add_argument('--cpp-verifier', default=os.environ.get('FB_CPP_VERIFIER'))
parser.add_argument('--flatc-das', default=os.environ.get('FLATC_DAS'))
parser.add_argument('--flatbuffers-source', default=os.environ.get('FLATBUFFERS_SOURCE'))
OPTIONS, REST = parser.parse_known_args()

def executable(value):
    found = shutil.which(value)
    if found:
        return str(Path(found).resolve())
    p = Path(value).resolve()
    if p.is_file():
        return str(p)
    raise RuntimeError(f'Executable not found: {value}')

DAS = executable(OPTIONS.daslang)
FLATC = executable(OPTIONS.flatc)

def run(*args, success=True):
    result = subprocess.run([str(a) for a in args], cwd=ROOT, capture_output=True,
                            encoding='utf-8', errors='replace', timeout=60)
    output = result.stdout + result.stderr
    if success and result.returncode:
        raise AssertionError(f'Command failed ({result.returncode}): {args}\n{output}')
    if not success:
        if result.returncode == 0 or 'EXCEPTION_ACCESS_VIOLATION' in output:
            raise AssertionError(f'Expected a controlled rejection: {args}\n{output}')
    return output

def das(script, *args, success=True):
    return run(DAS, '-no-module-cache', '-no-dynamic-modules', script, '--', *args,
               success=success)

EXPECTED = {
    'enabled': False, 'i8': -128, 'u8': 255, 'i16': -32768, 'u16': 65535,
    'i32': -2147483647, 'u32': 4294967295, 'i64': -9223372036854775807,
    'u64': 18446744073709551615, 'f32': -3.5, 'f64': 1.2345678901234567,
    'text': 'Hello, UTF-8: こんにちは 世界', 'flags': [True, False, True],
    'bytes': [0, 128, 255], 'signed_bytes': [-128, 0, 127],
    'shorts': [-32768, 32767], 'ushorts': [0, 65535],
    'ints': [-2147483647, 2147483647], 'uints': [0, 4294967295],
    'longs': [-9223372036854775807, 9223372036854775807],
    'ulongs': [0, 18446744073709551615], 'floats': [-3.5, 0.125],
    'doubles': [-1.2345678901234567, 1e100],
}
NESTED = {
    'loadout': {'item': {'name': 'Sword', 'power': 99, 'color': 'Red'},
                'history': [{'name': 'Shield', 'power': -5, 'color': 'Blue'}]},
    'pose': {'tag': 255, 'pos': {'x': 3.5, 'tag': 17, 'color': 'Blue'},
             'weight': 1.2345678901234567, 'code': -1234},
    'items': [{'name': 'Shield', 'power': -5, 'color': 'Blue'}],
    'poses': [{'tag': 255, 'pos': {'x': 3.5, 'tag': 17, 'color': 'Blue'},
               'weight': 1.2345678901234567, 'code': -1234}],
    'color': 'Red', 'colors': ['Red', 'Green', 'Blue'], 'tiny': 'Max',
    'wide': 'High', 'wides': ['None', 'High'],
}

class Compatibility(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # A unique directory directly below the repo keeps generated relative imports valid.
        cls.temp = tempfile.TemporaryDirectory(prefix='test-output-', dir=ROOT)
        cls.out = Path(cls.temp.name)
        cls.addClassCleanup(cls.cleanup_output)
        print(run(FLATC, '--version').strip(), flush=True)
        das(ROOT / 'tests/interop.das', cls.out.as_posix())
        for name, data in [('from_flatc', EXPECTED), ('defaults', {})]:
            (cls.out / f'{name}.json').write_text(json.dumps(data, ensure_ascii=True), encoding='utf-8')
            run(FLATC, '-b', '--strict-json', '-o', cls.out, ROOT / 'tests/record.fbs', cls.out / f'{name}.json')
        for fbs in [ROOT / 'tests/record.fbs', cls.out / 'macro.fbs']:
            run(FLATC, '-b', '--schema', '-o', cls.out, fbs)
        das(ROOT / 'tools/generate.das', cls.out / 'record.bfbs', cls.out / 'generated.das', cls.out / 'normalized.fbs')
        das(ROOT / 'tests/nested_interop.das', cls.out.as_posix())
        shutil.copyfile(ROOT / 'tests/nested.fbs', cls.out / 'nested_reference.fbs')
        (cls.out / 'nested_flatc.json').write_text(json.dumps(NESTED), encoding='utf-8')
        run(FLATC, '-b', '--strict-json', '-o', cls.out, ROOT / 'tests/nested.fbs', cls.out / 'nested_flatc.json')
        (cls.out / 'nested_defaults.json').write_text('{}')
        run(FLATC, '-b', '-o', cls.out, ROOT / 'tests/nested.fbs', cls.out / 'nested_defaults.json')
        run(FLATC, '-b', '--schema', '-o', cls.out, cls.out / 'nested_reference.fbs')
        das(ROOT / 'tools/generate.das', cls.out / 'nested_reference.bfbs',
            cls.out / 'nested_generated.das', cls.out / 'nested_normalized.fbs')

        shutil.copyfile(ROOT / 'tests/optional.fbs', cls.out / 'optional_reference.fbs')
        cases = {
            'absent': {'mandatory': {}},
            'defaults': {'mandatory': {}, 'child': {}, 'sibling': {}},
            'values': {'child': {'power': 99, 'values': [1, 2, 3], 'leaf': {'value': 42}},
                       'mandatory': {'power': -3, 'leaf': {}}, 'children': [{}, {'leaf': {}}]},
        }
        for name, data in cases.items():
            path = cls.out / f'optional_flatc_{name}.json'
            path.write_text(json.dumps(data), encoding='utf-8')
            run(FLATC, '-b', '--strict-json', '-o', cls.out, ROOT / 'tests/optional.fbs', path)
        run(FLATC, '-b', '--schema', '-o', cls.out, cls.out / 'optional_reference.fbs')
        das(ROOT / 'tools/generate.das', cls.out / 'optional_reference.bfbs',
            cls.out / 'optional_generated.das', cls.out / 'optional_normalized.fbs')

    @classmethod
    def cleanup_output(cls):
        assert cls.out.resolve().parent == ROOT.resolve()
        cls.temp.cleanup()

    def json_buffer(self, path):
        run(FLATC, '-t', '--strict-json', '--defaults-json', '-o', self.out,
            ROOT / 'tests/record.fbs', '--', path)
        return json.loads(path.with_suffix('.json').read_text())

    def assert_values(self, actual, expected):
        if isinstance(expected, dict):
            self.assertEqual(set(actual), set(expected))
            for k, v in expected.items():
                self.assert_values(actual[k], v)
        elif isinstance(expected, list):
            self.assertEqual(len(actual), len(expected))
            for a, b in zip(actual, expected):
                self.assert_values(a, b)
        elif isinstance(expected, float):
            # flatc's JSON printer uses limited decimal precision; direct daScript
            # assertions additionally check the exact float64 round trip.
            self.assertTrue(math.isclose(actual, expected, rel_tol=1e-11, abs_tol=1e-15), (actual, expected))
        else:
            self.assertEqual(actual, expected)

    def script(self, name, body):
        path = self.out / f'{name}.das'
        path.write_text('options gen2\n' + body, encoding='utf-8')
        return path

    def test_01_macro_to_flatc(self):
        self.assert_values(self.json_buffer(self.out / 'from_das.bin'), EXPECTED)

    def test_02_flatc_to_macro_and_defaults(self):
        self.assertIn('macro interop OK', das(ROOT / 'tests/interop.das', self.out.as_posix()))
        self.assert_values(self.json_buffer(self.out / 'flatc_repacked.bin'), EXPECTED)

    def test_03_bfbs_generated_code(self):
        src = self.script('consume', '''require ./generated.das
require ../src/runtime.das
require daslib/fio
[export]
def main {
    let args <- get_command_line_arguments()
    let folder = args[length(args)-1]
    let b <- fb_load(folder + "/from_flatc.bin")
    let value <- fb_unpack_compat_Record(b)
    assert(value.u64 == 18446744073709551615ul)
    assert(value.f64 == 1.2345678901234567lf)
    fb_save(folder + "/generated_repacked.bin", fb_pack_compat_Record(value))
    verify(fwrite(folder + "/generated_schema.fbs", fb_schema_compat_Record()))
    let defaults <- fb_load(folder + "/defaults.bin")
    let d <- fb_unpack_compat_Record(defaults)
    assert(d.u64 == 9000000000000000000ul && d.i8 == int8(-12))
    print("generated interop OK\\n")
}
''')
        self.assertIn('generated interop OK', das(src, self.out.as_posix()))
        self.assert_values(self.json_buffer(self.out / 'generated_repacked.bin'), EXPECTED)

    def schema_shape(self, name):
        fbs = self.out / f'{name}.fbs'
        run(FLATC, '-b', '--schema', '-o', self.out, fbs)
        run(FLATC, '-t', '--strict-json', '--defaults-json', '-o', self.out,
            ROOT / 'third_party/flatbuffers/reflection.fbs', '--', fbs.with_suffix('.bfbs'))
        data = json.loads(fbs.with_suffix('.json').read_text())
        def strip(value):
            if isinstance(value, dict):
                return {k: strip(v) for k, v in value.items()
                        if k not in {'declaration_file', 'fbs_files', 'documentation'}}
            if isinstance(value, list):
                return [strip(x) for x in value]
            return value
        return strip(data)

    def test_04_schema_equivalence(self):
        shutil.copyfile(ROOT / 'tests/record.fbs', self.out / 'reference.fbs')
        reference = self.schema_shape('reference')
        self.assertEqual(reference, self.schema_shape('macro'))
        self.assertEqual(reference, self.schema_shape('normalized'))
        # Also force compilation of output from the FBS-first path, then export it again.
        self.test_03_bfbs_generated_code()
        self.assertEqual(reference, self.schema_shape('generated_schema'))

    def test_05_schema_evolution(self):
        (self.out / 'old.fbs').write_text('namespace compat; table Record { enabled:bool = true; } root_type Record; file_identifier "TEST";')
        (self.out / 'old.json').write_text('{"enabled":false}')
        run(FLATC, '-b', '-o', self.out, self.out / 'old.fbs', self.out / 'old.json')
        src = self.script('evolution', '''require ../tests/model.das
require ../src/runtime.das
[export]
def main {
    let args <- get_command_line_arguments()
    let b <- fb_load(args[length(args)-1])
    let v <- fb_unpack_Record(b)
    assert(!v.enabled && v.i32 == -1234567 && v.u64 == 9000000000000000000ul)
    assert(empty(v.bytes))
}
''')
        das(src, self.out / 'old.bin')
        newer = (ROOT / 'tests/record.fbs').read_text()
        newer = newer.replace('  removed:int', '  future:long = 77 (id:24);\n  removed:int')
        (self.out / 'new.fbs').write_text(newer)
        (self.out / 'new.json').write_text('{"enabled":false,"future":123}')
        run(FLATC, '-b', '-o', self.out, self.out / 'new.fbs', self.out / 'new.json')
        das(src, self.out / 'new.bin')

    def test_06_macro_errors(self):
        cases = [
            ('duplicate', '@fb_id=0\na:int\n@fb_id=0\nb:int', 'duplicate field id'),
            ('gap', '@fb_id=1\na:int', 'contiguous'),
            ('missing', 'a:int', 'contiguous'),
            ('pointer', '@fb_id=0\na:int?', 'unsupported field type'),
            ('nested', '@fb_id=0\na:array<array<int>>', 'unsupported field type'),
            ('required_scalar', '@fb_id=0\n@fb_required\na:int', 'required'),
            ('annotation', '@fb_id=0\n@fb_typo\na:int', 'invalid field annotation'),
            ('initializer', '@fb_id=0\na:string="hello"', 'initializers'),
            ('large_default', '@fb_id=0\na:uint64=18446744073709551615ul', 'default'),
        ]
        for name, fields, message in cases:
            with self.subTest(name=name):
                src = self.script(name, 'require ../src/annotations.das\n[fb_table]\nstruct Bad {\n' + fields + '\n}\n[export]\ndef main {}\n')
                self.assertIn(message, das(src, success=False))

    def test_07_newly_supported_bfbs(self):
        cases = [
            ('optional', 'table Bad { n:int=null; }', 'advanced_features'),
            ('fixed_array', 'struct Vec { x:[float:3]; } table Bad { v:Vec; }', 'advanced_features'),
            ('key', 'table Bad { n:int (key); }', 'key'),
            ('union_type', 'table Child { n:int; } union E { Child } table Bad { e:E; }', 'unions'),
            ('keyword', 'table Bad { var:int; }', 'keyword'),
        ]
        for name, schema, message in cases:
            with self.subTest(name=name):
                path = self.out / f'{name}.fbs'
                path.write_text(schema + '\nroot_type Bad;')
                run(FLATC, '-b', '--schema', '-o', self.out, path)
                result = das(ROOT / 'tools/generate.das', path.with_suffix('.bfbs'),
                             self.out / f'{name}_out.das', self.out / f'{name}_out.fbs')
                consumer = self.script(f'{name}_positive', f'require ./{name}_out.das\n[export]\ndef main {{ var value=Bad(); let bytes <- fb_pack_Bad(value); let back <- fb_unpack_Bad(bytes) }}')
                das(consumer)

    def test_08_malformed_buffers(self):
        src = self.script('malformed', '''require ../tests/model.das
require ../src/runtime.das
[export]
def main {
    let args <- get_command_line_arguments()
    let b <- fb_load(args[length(args)-1])
    let v <- fb_unpack_Record(b)
    print("{v.text}\\n")
}
''')
        raw = (self.out / 'from_das.bin').read_bytes()
        variants = [raw[:3], b'\xff\xff\xff\xff' + raw[4:], raw[:4]+b'FAIL'+raw[8:]]
        root = struct.unpack_from('<I', raw)[0]
        vt = root - struct.unpack_from('<i', raw, root)[0]
        corrupt = bytearray(raw)
        struct.pack_into('<H', corrupt, vt, 1)
        variants.append(corrupt)
        # Corrupt string/vector lengths and string terminator independently.
        for field in (11, 13):
            off = struct.unpack_from('<H', raw, vt+4+field*2)[0]
            slot = root+off
            obj = slot + struct.unpack_from('<I', raw, slot)[0]
            corrupt = bytearray(raw)
            struct.pack_into('<I', corrupt, obj, 0xffffffff)
            variants.append(corrupt)
            if field == 11:
                corrupt = bytearray(raw)
                corrupt[obj+4+struct.unpack_from('<I', raw, obj)[0]] = 1
                variants.append(corrupt)
        for i, data in enumerate(variants):
            with self.subTest(case=i):
                path = self.out / f'broken_{i}.bin'
                path.write_bytes(data)
                self.assertIn('FlatBuffers:', das(src, path, success=False))
        bfbs = self.out / 'broken.bfbs'
        bfbs.write_bytes(b'\x00\x00\x00\x00BFBS')
        self.assertIn('FlatBuffers:', das(ROOT / 'tools/generate.das', bfbs,
                      self.out / 'broken_output.das', self.out / 'broken_output.fbs', success=False))

    def test_09_required_fields(self):
        src = self.script('required', '''require ../src/annotations.das
require ../src/runtime.das
[fb_table(identifier="REQD", root=true)]
struct Required {
    @fb_id=0
    @fb_required
    text:string
    @fb_id=1
    @fb_required
    items:array<int>
}
[export]
def main {
    let args <- get_command_line_arguments()
    let b <- fb_load(args[length(args)-1])
    let v <- fb_unpack_Required(b)
    print("{v.text}\\n")
}
''')
        # Produce a structurally valid table with omitted fields using flatc,
        # then have the stricter generated reader enforce its required contract.
        path = self.out / 'req.fbs'
        path.write_text('table Required { text:string; items:[int]; } root_type Required; file_identifier "REQD";')
        for name, data, expected in [('missing_text', {}, 'required string'),
                                     ('missing_items', {'text': ''}, 'required vector')]:
            js = self.out / f'{name}.json'
            js.write_text(json.dumps(data))
            run(FLATC, '-b', '-o', self.out, path, js)
            self.assertIn(expected, das(src, js.with_suffix('.bin'), success=False))

    def test_10_namespaces_and_field_order(self):
        source = self.out / 'namespaces.fbs'
        source.write_text('''namespace a;
table A { last:int (id:1); first:string (id:0); }
namespace;
table B { number:int; }
root_type B;
''')
        run(FLATC, '-b', '--schema', '-o', self.out, source)
        das(ROOT / 'tools/generate.das', source.with_suffix('.bfbs'),
            self.out / 'namespaces_generated.das', self.out / 'namespaces_roundtrip.fbs')
        self.assertEqual(self.schema_shape('namespaces'), self.schema_shape('namespaces_roundtrip'))
        consumer = self.script('namespaces_consumer', '''require ./namespaces_generated.das
[export]
def main {
    var a = a_A()
    a.first <- some("first")
    a.last = 7
    let buffer <- fb_pack_a_A(a)
    let b <- fb_unpack_a_A(buffer)
    assert(b.first is some && (b.first as some) == "first" && b.last == 7)
    var v = B()
    v.number = 19
    let bytes <- fb_pack_B(v)
    let w <- fb_unpack_B(bytes)
    assert(w.number == 19)
}
''')
        das(consumer)
        # The hand-authored macro must use IDs, not source order, too.
        reordered = self.script('reordered', '''require ../src/annotations.das
[fb_table]
struct Reordered {
    @fb_id=1
    last:int
    @fb_id=0
    first:string
}
[export]
def main {
    var value = Reordered()
    value.first = "ok"
    value.last = -17
    let b <- fb_pack_Reordered(value)
    let q <- fb_unpack_Reordered(b)
    assert(q.first == "ok" && q.last == -17)
}
''')
        das(reordered)

    def test_11_empty_table_validation(self):
        src = self.script('empty_table', '''require ../src/annotations.das
require ../src/runtime.das
[fb_table(root=true)]
struct Empty {}
[export]
def main {
    let args <- get_command_line_arguments()
    let path = args[length(args)-1]
    if (path == "valid") {
        let e = Empty()
        let b <- fb_pack_Empty(e)
        let q <- fb_unpack_Empty(b)
        print("empty OK\\n")
    } else {
        let b <- fb_load(path)
        let q <- fb_unpack_Empty(b)
    }
}
''')
        self.assertIn('empty OK', das(src, 'valid'))
        invalid = self.out / 'empty_invalid.bin'
        invalid.write_bytes(struct.pack('<II', 4, 0))
        self.assertIn('FlatBuffers:', das(src, invalid, success=False))

    def nested_json(self, path):
        run(FLATC, '-t', '--strict-json', '--defaults-json', '-o', self.out,
            ROOT / 'tests/nested.fbs', '--', path)
        return json.loads(path.with_suffix('.json').read_text())

    def test_12_nested_macro_interoperability(self):
        self.assert_values(self.nested_json(self.out / 'nested_das.bin'), NESTED)
        self.assertIn('nested macro OK', das(ROOT / 'tests/nested_interop.das', self.out.as_posix()))
        self.assert_values(self.nested_json(self.out / 'nested_repacked.bin'), NESTED)

    def nested_consumer(self):
        return self.script('nested_consumer', '''require ./nested_generated.das
require ../src/runtime.das
require daslib/fio
[export]
def main {
    let args <- get_command_line_arguments()
    let folder = args[length(args)-1]
    let b <- fb_load(folder + "/nested_flatc.bin")
    let value <- fb_unpack_world_Scene(b)
    assert(value.loadout is some && ((value.loadout as some).item.name as some) == "Sword")
    assert((value.pose as some).weight == 1.2345678901234567lf)
    assert(value.wide == world_Wide.High && value.tiny == world_Tiny.Max)
    assert((value.colors as some)[0] == world_Color.Red && (value.poses as some)[0].code == int16(-1234))
    fb_save(folder + "/nested_generated_repacked.bin", fb_pack_world_Scene(value))
    verify(fwrite(folder + "/nested_generated_schema.fbs", fb_schema_world_Scene()))
    let defaults <- fb_load(folder + "/nested_defaults.bin")
    let empty_value <- fb_unpack_world_Scene(defaults)
    assert(empty_value.color == world_Color.Blue && empty_value.tiny == world_Tiny.Max)
    assert(empty_value.loadout is none && empty_value.poses is none)
    let p <- fb_pack_world_Pose((value.pose as some))
    assert(length(p) == 32)
    let pose <- fb_unpack_world_Pose(p)
    assert(pose.pos.x == 3.5 && pose.weight == (value.pose as some).weight)
    print("nested generated OK\\n")
}
''')

    def test_13_nested_bfbs_interoperability(self):
        self.assertIn('nested generated OK', das(self.nested_consumer(), self.out.as_posix()))
        self.assert_values(self.nested_json(self.out / 'nested_generated_repacked.bin'), NESTED)

    def test_14_nested_schema_and_layout(self):
        das(self.nested_consumer(), self.out.as_posix())
        reference = self.schema_shape('nested_reference')
        self.assertEqual(reference, self.schema_shape('nested_macro'))
        self.assertEqual(reference, self.schema_shape('nested_normalized'))
        self.assertEqual(reference, self.schema_shape('nested_generated_schema'))
        objects = {o['name']: o for o in reference['objects']}
        pose = objects['world.Pose']
        self.assertEqual((pose['minalign'], pose['bytesize']), (16, 32))
        self.assertEqual({f['name']: (f['offset'], f['padding']) for f in pose['fields']},
                         {'tag': (0, 3), 'pos': (4, 4), 'weight': (16, 0), 'code': (24, 6)})
        vec = objects['world.Vec']
        self.assertEqual((vec['minalign'], vec['bytesize']), (4, 8))

    def test_15_nested_validation(self):
        cases = [
            ('struct_string', '[fb_struct]\nstruct Bad { text:string }', 'fixed structs support'),
            ('struct_vector', '[fb_struct]\nstruct Bad { nums:array<int> }', 'fixed structs support'),
            ('struct_table', '[fb_table]\nstruct Child { @fb_id=0\nx:int }\n[fb_struct]\nstruct Bad { child:Child }', 'cannot contain a table'),
            ('struct_default', '[fb_struct]\nstruct Bad { x:int=2 }', 'cannot have defaults'),
            ('struct_alignment', '[fb_struct(align=3)]\nstruct Bad { x:int }', 'invalid force_align'),
            ('struct_ids', '[fb_struct]\nstruct Bad { @fb_id=1\nx:int }', 'field order'),
            ('enum_default', '[fb_enum]\nenum E { A=1 }\n[fb_table]\nstruct Bad { @fb_id=0\ne:E }', 'enum default'),
            ('untagged_enum', 'enum E { A=0 }\n[fb_table]\nstruct Bad { @fb_id=0\ne:E }', 'requires fb_enum'),
            ('object_override', '[fb_table]\nstruct Child { @fb_id=0\nx:int }\n[fb_table]\nstruct Bad { @fb_id=0\nc:Child=Child(x=42) }', 'initializers'),
            ('enum_large_default', '[fb_enum]\nenum E:uint64 { Zero=0ul\nHigh=18446744073709551615ul }\n[fb_table]\nstruct Bad { @fb_id=0\ne:E=E.High }', 'default exceeds'),
        ]
        for name, body, message in cases:
            with self.subTest(name=name):
                source = self.script(name, 'require ../src/annotations.das\n'+body+'\n[export]\ndef main {}\n')
                self.assertIn(message, das(source, success=False))

    def test_16_nested_malformed_and_required(self):
        raw = (self.out / 'nested_das.bin').read_bytes()
        root = struct.unpack_from('<I', raw)[0]
        vt = root - struct.unpack_from('<i', raw, root)[0]
        def slot(field):
            return root + struct.unpack_from('<H', raw, vt+4+2*field)[0]
        variants = []
        corrupt = bytearray(raw)
        struct.pack_into('<I', corrupt, slot(0), 0xffffffff)
        variants.append(corrupt)
        corrupt = bytearray(raw)
        loadout = slot(0)+struct.unpack_from('<I', raw, slot(0))[0]
        loadout_vt = loadout-struct.unpack_from('<i', raw, loadout)[0]
        struct.pack_into('<H', corrupt, loadout_vt+4, 0)  # required child omitted
        variants.append(corrupt)
        corrupt = bytearray(raw)
        object_size = struct.unpack_from('<H', raw, vt+2)[0]
        struct.pack_into('<H', corrupt, vt+4+2, object_size-1)  # inline Pose overruns parent
        variants.append(corrupt)
        for field in (2, 3):  # vectors of tables and structs
            corrupt = bytearray(raw)
            vector = slot(field)+struct.unpack_from('<I', raw, slot(field))[0]
            struct.pack_into('<I', corrupt, vector, 0xffffffff)
            variants.append(corrupt)
        for mode, require, typename in [('macro', '../tests/nested_model.das', 'Scene'),
                                         ('bfbs', './nested_generated.das', 'world_Scene')]:
            source = self.script(f'nested_bad_{mode}', f'''require {require}
require ../src/runtime.das
[export]
def main {{
    let args <- get_command_line_arguments()
    let b <- fb_load(args[length(args)-1])
    let v <- fb_unpack_{typename}(b)
    print("{{v.color}}\\n")
}}
''')
            for i, data in enumerate(variants):
                with self.subTest(mode=mode, corruption=i):
                    path = self.out / f'nested_broken_{i}.bin'
                    path.write_bytes(data)
                    self.assertIn('FlatBuffers:', das(source, path, success=False))

    def test_17_enum_backing_widths_and_unknown_values(self):
        types = [('byte','int8',-128,127), ('ubyte','uint8',0,255),
                 ('short','int16',-32768,32767), ('ushort','uint16',0,65535),
                 ('int','int',-2147483648,2147483647), ('uint','uint',0,4294967295),
                 ('long','int64',-9223372036854775808,9223372036854775807),
                 ('ulong','uint64',0,18446744073709551615)]
        schema = []
        native = ['require ../src/annotations.das']
        for i, (fbs, ds, lo, hi) in enumerate(types):
            members = [('Low',lo)] if lo < 0 else []
            members += [('Zero',0), ('High',hi)]
            schema.append(f'enum E{i}:{fbs} {{'+','.join(f'{k}={v}' for k,v in members)+'}')
            suffix = 'ul' if ds == 'uint64' else 'l' if ds == 'int64' else 'u' if ds == 'uint' else ''
            literals = {-2147483648: 'int(0x80000000u)', -9223372036854775808: 'int64(0x8000000000000000ul)'}
            native += [f'[fb_enum]\nenum E{i}:{ds} {{']+[f'{k}={literals.get(v, str(v)+suffix)}' for k,v in members]+['}']
        fields = [f'e{i}:E{i} (id:{i});' for i in range(8)]
        schema += ['table Enums {'+''.join(fields)+'}', 'root_type Enums;']
        native += ['[fb_table(root=true)]\nstruct Enums {']
        native += [f'@fb_id={i}\ne{i}:E{i}=E{i}.Zero' for i in range(8)]
        native += ['}']
        fbs_path = self.out / 'enums.fbs'
        fbs_path.write_text('\n'.join(schema))
        # Unknown numeric enum values are forward-compatible data, not bad schemas.
        enum_values = {f'e{i}': (lo if i % 2 == 0 else hi) for i,(_,_,lo,hi) in enumerate(types)}
        enum_values['e4'] = 42
        js = self.out / 'enum_values.json'
        js.write_text(json.dumps(enum_values))
        run(FLATC, '-b', '--schema', '-o', self.out, fbs_path)
        run(FLATC, '-b', '--strict-json', '-o', self.out, fbs_path, js)
        das(ROOT / 'tools/generate.das', fbs_path.with_suffix('.bfbs'),
            self.out / 'enum_generated.das', self.out / 'enum_normalized.fbs')
        for mode in ('macro', 'bfbs'):
            header = '\n'.join(native) if mode == 'macro' else 'require ./enum_generated.das'
            source = self.script(f'enum_consumer_{mode}', header+'''
require ../src/runtime.das
[export]
def main {
    let args <- get_command_line_arguments()
    let b <- fb_load(args[length(args)-2])
    let value <- fb_unpack_Enums(b)
    assert(int(value.e0) == -128 && uint(value.e1) == 255u)
    assert(int(value.e2) == -32768 && uint(value.e3) == 65535u)
    assert(int(value.e4) == 42 && uint(value.e5) == 4294967295u)
    assert(int64(value.e6) == -9223372036854775807l - 1l)
    assert(uint64(value.e7) == 18446744073709551615ul)
    fb_save(args[length(args)-1], fb_pack_Enums(value))
}
''')
            binary = self.out / f'enum_{mode}.bin'
            das(source, js.with_suffix('.bin'), binary)
            run(FLATC, '-t', '--strict-json', '--defaults-json', '--raw-binary', '-o', self.out, fbs_path, '--', binary)
            decoded = json.loads(binary.with_suffix('.json').read_text())
            self.assertEqual(decoded['e4'], 42)
            self.assertEqual(decoded['e7'], 'High')

    def test_18_recursive_table_vectors_and_depth_limit(self):
        fbs = self.out / 'tree.fbs'
        fbs.write_text('table Node { children:[Node] (id:0); } root_type Node;')
        run(FLATC, '-b', '--schema', '-o', self.out, fbs)
        das(ROOT / 'tools/generate.das', fbs.with_suffix('.bfbs'),
            self.out / 'tree_generated.das', self.out / 'tree_normalized.fbs')
        for mode in ('macro', 'bfbs'):
            header = ('require ../src/annotations.das\n[fb_table(root=true)]\nstruct Node { @fb_id=0\nchildren:array<Node> }'
                      if mode == 'macro' else 'require ./tree_generated.das')
            body = '''
require ../src/runtime.das
def node(depth:int) : Node {
    var result = Node()
    if (depth > 0) { var child <- node(depth-1); emplace(result.children, child) }
    return <- result
}
[export]
def main {
    let args <- get_command_line_arguments()
    let mode = args[length(args)-1]
    if (mode == "valid") {
        let n <- node(4)
        let b <- fb_pack_Node(n)
        let roundtrip <- fb_unpack_Node(b)
        assert(length(roundtrip.children[0].children) == 1)
    } elif (mode == "encode") {
        let n <- node(66)
        let b <- fb_pack_Node(n)
    } else {
        // Build a valid deep buffer without using the generated recursion guard.
        var leaf <- fb_begin(1, "")
        var bytes <- leaf.bytes
        for (i in range(66)) {
            var parent <- fb_begin(1, "")
            var children : array<array<uint8>>
            emplace(children, bytes)
            fb_write_objects(parent, 0, children, 4, 8, false)
            bytes <- parent.bytes
        }
        let n <- fb_unpack_Node(bytes)
    }
}
'''
            if mode == 'bfbs':
                body = body.replace('emplace(result.children, child)', 'var children:array<Node>; emplace(children,child); result.children <- move_some(children)')
                body = body.replace('roundtrip.children[0].children', '((roundtrip.children as some)[0].children as some)')
            source=self.script(f'tree_{mode}', 'options stack=262144\n'+header+body)
            das(source, 'valid')
            self.assertIn('nesting exceeds 64', das(source, 'encode', success=False))
            self.assertIn('nesting exceeds 64', das(source, 'decode', success=False))

    def test_19_cross_module_and_missing_nested_defaults(self):
        source = self.script('cross_module', '''require ../tests/nested_model.das
require ../src/annotations.das
[fb_table(root=true)]
struct Envelope {
    @fb_id=0
    value:Item
    @fb_id=1
    pos:Pose
}
[export]
def main {
    var envelope = Envelope()
    envelope.value.name = "cross module"
    envelope.pos.pos.color = Color.Green
    let b <- fb_pack_Envelope(envelope)
    let q <- fb_unpack_Envelope(b)
    assert(q.value.name == "cross module" && q.value.power == 7)
    assert(q.pos.pos.color == Color.Green)
}
''')
        das(source)

    def test_20_reflected_layout_corruption(self):
        raw = bytearray((self.out / 'nested_reference.bfbs').read_bytes())
        def field(data, table, ident):
            vt = table-struct.unpack_from('<i', data, table)[0]
            n = struct.unpack_from('<H', data, vt)[0]
            if 4+2*ident >= n:
                return None
            off = struct.unpack_from('<H', data, vt+4+2*ident)[0]
            return table+off if off else None
        def indirect(data, slot):
            return slot+struct.unpack_from('<I', data, slot)[0]
        root = struct.unpack_from('<I', raw)[0]
        objects = indirect(raw, field(raw, root, 0))
        pose = None
        for i in range(struct.unpack_from('<I', raw, objects)[0]):
            obj = indirect(raw, objects+4+i*4)
            name = indirect(raw, field(raw, obj, 0))
            size = struct.unpack_from('<I', raw, name)[0]
            if raw[name+4:name+4+size] == b'world.Pose':
                pose = obj
        self.assertIsNotNone(pose)
        for key, value in [(3, 3), (4, 999)]:
            corrupted = bytearray(raw)
            struct.pack_into('<I', corrupted, field(raw, pose, key), value)
            path = self.out / f'bad_layout_{key}.bfbs'
            path.write_bytes(corrupted)
            result = das(ROOT / 'tools/generate.das', path, self.out / f'bad_layout_{key}.das',
                         self.out / f'bad_layout_{key}.fbs', success=False)
            self.assertIn('struct size/alignment', result)

    def optional_consumer(self, mode):
        module = '../tests/optional_model.das' if mode == 'macro' else './optional_generated.das'
        prefix = '' if mode == 'macro' else 'presence_'
        body = '''require MODULE
require daslib/fio
[generic]
def check(value : auto(T); scenario : int) {
    assert((value.child is some) == (scenario != 0))
    assert((value.sibling is some) == (scenario == 1))
    if (scenario == 0) {
        assert(value.mandatory.power == 7 && value.mandatory.leaf is none)
    } elif (scenario == 1) {
        assert((value.child as some).power == 7 && (value.child as some).leaf is none)
        assert((value.sibling as some).power == 7)
    } else {
        assert((value.child as some).power == 99 && length((value.child as some).values) == 3)
        assert((value.child as some).values[2] == 3)
        assert((value.child as some).leaf is some && ((value.child as some).leaf as some).value == 42)
        assert(value.mandatory.power == -3 && value.mandatory.leaf is some)
        assert((value.mandatory.leaf as some).value == 11)
        assert(length(value.children) == 2)
        assert(value.children[0].leaf is none && value.children[1].leaf is some)
        assert((value.children[1].leaf as some).value == 11)
    }
}
[export]
def main {
    let args <- get_command_line_arguments()
    let folder = args[length(args)-1]
    let names <- ["absent", "defaults", "values"]
    for (scenario in range(3)) {
        var obj = TYPE_Envelope()
        if (scenario == 1) {
            obj.child <- some(TYPE_Child())
            obj.sibling <- some(TYPE_Child())
        } elif (scenario == 2) {
            var child = TYPE_Child()
            child.power = 99
            child.values <- [1,2,3]
            child.leaf <- some(TYPE_Leaf(value=42))
            obj.child <- move_some(child)
            obj.mandatory.power = -3
            obj.mandatory.leaf <- some(TYPE_Leaf())
            var item = TYPE_Child()
            push_clone(obj.children, item)
            item.leaf <- some(TYPE_Leaf())
            emplace(obj.children, item)
        }
        let bytes <- fb_pack_TYPE_Envelope(obj)
        let root = fb_root(bytes, "OPTN")
        verify((fb_field(bytes, root, 0, 4) != 0) == (scenario != 0))
        verify((fb_field(bytes, root, 3, 4) != 0) == (scenario == 1))
        verify(fb_field(bytes, root, 1, 4) != 0)
        let back <- fb_unpack_TYPE_Envelope(bytes)
        check(back, scenario)
        fb_save(folder + "/optional_MODE_" + names[scenario] + ".bin", bytes)
        let foreign <- fb_load(folder + "/optional_flatc_" + names[scenario] + ".bin")
        let value <- fb_unpack_TYPE_Envelope(foreign)
        check(value, scenario)
        fb_save(folder + "/optional_MODE_repacked_" + names[scenario] + ".bin", fb_pack_TYPE_Envelope(value))
    }
    // Remove a previously present child explicitly; serializing none must omit it.
    var obj = TYPE_Envelope()
    obj.child <- some(TYPE_Child())
    obj.child <- none(type<TYPE_Child>)
    let cleared <- fb_unpack_TYPE_Envelope(fb_pack_TYPE_Envelope(obj))
    assert(cleared.child is none)
    verify(fwrite(folder + "/optional_MODE_schema.fbs", fb_schema_TYPE_Envelope()))
    let ir <- fb_schema_ir_TYPE_Envelope()
    let index = fb_object_index(ir, "presence.Envelope")
    assert(ir.tables[index].fields[0].optional_table && !ir.tables[index].fields[1].optional_table)
    print("optional MODE OK\\n")
}
'''
        if mode == 'bfbs':
            body = body.replace('(value.child as some).values', '((value.child as some).values as some)')
            body = body.replace('value.children', '(value.children as some)')
            body = body.replace('child.values <- [1,2,3]', 'child.values <- some([1,2,3])')
            body = body.replace('push_clone(obj.children, item)', 'var items:array<TYPE_Child>; push_clone(items,item)')
            body = body.replace('emplace(obj.children, item)', 'emplace(items,item); obj.children <- move_some(items)')
        return self.script(f'optional_consumer_{mode}', body.replace('MODULE', module).replace('TYPE_', prefix).replace('MODE', mode))

    def check_optional_interop(self, mode):
        self.assertIn(f'optional {mode} OK', das(self.optional_consumer(mode), self.out.as_posix()))
        default_child = {'power': 7, 'values': []}
        expected = {
            'absent': {'mandatory': default_child, 'children': []},
            'defaults': {'child': default_child, 'sibling': default_child,
                         'mandatory': default_child, 'children': []},
            'values': {'child': {'power': 99, 'values': [1, 2, 3], 'leaf': {'value': 42}},
                       'mandatory': {'power': -3, 'values': [], 'leaf': {'value': 11}},
                       'children': [default_child, {**default_child, 'leaf': {'value': 11}}]},
        }
        if mode == 'bfbs':
            def omit_empty_vectors(value):
                if isinstance(value, dict):
                    return {k:omit_empty_vectors(v) for k,v in value.items() if v != []}
                if isinstance(value,list):
                    return [omit_empty_vectors(v) for v in value]
                return value
            expected=omit_empty_vectors(expected)
        for name, value in expected.items():
            for repacked in ['', 'repacked_']:
                with self.subTest(mode=mode, case=name, repacked=repacked):
                    path = self.out / f'optional_{mode}_{repacked}{name}.bin'
                    run(FLATC, '-t', '--strict-json', '--defaults-json', '-o', self.out,
                        ROOT / 'tests/optional.fbs', '--', path)
                    self.assertEqual(json.loads(path.with_suffix('.json').read_text()), value)

    def test_21_optional_macro_interoperability(self):
        self.check_optional_interop('macro')

    def test_22_optional_bfbs_interoperability(self):
        self.check_optional_interop('bfbs')

    def test_23_optional_schema_equivalence(self):
        reference = self.schema_shape('optional_reference')
        self.assertEqual(reference, self.schema_shape('optional_normalized'))
        for mode in ['macro', 'bfbs']:
            das(self.optional_consumer(mode), self.out.as_posix())
            self.assertEqual(reference, self.schema_shape(f'optional_{mode}_schema'))

    def test_24_optional_validation(self):
        cases = [
            ('required', 'Option<Child>', '@fb_required', 'non-required table'),
            ('vector_element', 'array<Option<Child>>', '', 'invalid Option payload'),
            ('nested_option', 'Option<Option<Child>>', '', 'invalid Option payload'),
            ('initializer', 'Option<Child> = some(Child())', '', 'initializers'),
        ]
        for name, typ, annotation, message in cases:
            with self.subTest(case=name):
                src = self.script('optional_invalid_'+name, f'''require ../tests/optional_model.das
[fb_struct]
struct Fixed {{ x:int }}
[fb_table]
struct Bad {{
    @fb_id=0
    {annotation}
    item : {typ}
}}
[export]
def main {{}}
''')
                self.assertIn(message, das(src, success=False))

    def test_25_optional_malformed_and_required(self):
        raw = (self.out / 'optional_flatc_defaults.bin').read_bytes()
        root = struct.unpack_from('<I', raw)[0]
        vt = root-struct.unpack_from('<i', raw, root)[0]
        slot = root+struct.unpack_from('<H', raw, vt+4)[0]
        variants = []
        for offset in [0, 1, 0xffffffff]:
            corrupt = bytearray(raw)
            struct.pack_into('<I', corrupt, slot, offset)
            variants.append((corrupt, 'FlatBuffers:'))
        corrupt = bytearray(raw)
        child = slot+struct.unpack_from('<I', raw, slot)[0]
        struct.pack_into('<i', corrupt, child, 0x7fffffff)
        variants.append((corrupt, 'FlatBuffers:'))
        corrupt = bytearray(raw)
        struct.pack_into('<H', corrupt, vt+6, 0)  # required sibling omitted
        variants.append((corrupt, 'missing required object'))
        for mode, module, prefix in [('macro', '../tests/optional_model.das', ''),
                                      ('bfbs', './optional_generated.das', 'presence_')]:
            src = self.script('optional_broken_'+mode, f'''require {module}
[export]
def main {{
    let args <- get_command_line_arguments()
    let data <- fb_load(args[length(args)-1])
    let value <- fb_unpack_{prefix}Envelope(data)
    print("{{value.mandatory.power}}\\n")
}}
''')
            for i, (data, message) in enumerate(variants):
                with self.subTest(mode=mode, corruption=i):
                    path = self.out / f'optional_broken_{i}.bin'
                    path.write_bytes(data)
                    self.assertIn(message, das(src, path, success=False))

if __name__ == '__main__':
    unittest.main(argv=[__file__]+REST, verbosity=2)
