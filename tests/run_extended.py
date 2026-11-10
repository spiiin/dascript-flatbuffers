"""Expanded wire-format tests. All schemas are independent flatc oracles."""
import json
import os
from pathlib import Path
import random
import shutil
import struct
import subprocess
import tempfile
import unittest
from run_tests import ROOT, DAS, FLATC, OPTIONS, REST, run, das

class Extended(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='extended-', dir=ROOT)
        self.out = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)

    def script(self, name, source):
        path = self.out / (name+'.das')
        path.write_text('options gen2\noptions stack=262144\n'+source, encoding='utf-8')
        return path

    def typed_verifier(self, checks=''):
        self.assertTrue(OPTIONS.flatbuffers_source, 'Pass --flatbuffers-source for typed C++ verifier tests')
        source=Path(OPTIONS.flatbuffers_source).resolve().as_posix()
        (self.out/'verify_typed.cpp').write_text('''#include <fstream>
#include <iterator>
#include <vector>
#include "oracle_generated.h"
int main(int argc,char**argv){
  if(argc<2)return 2;
  std::ifstream f(argv[1],std::ios::binary);
  std::vector<uint8_t>b{std::istreambuf_iterator<char>(f),std::istreambuf_iterator<char>()};
  flatbuffers::Verifier v(b.data(),b.size());
  bool prefix=argc==3;
  if(!(prefix?VerifySizePrefixedRootBuffer(v):VerifyRootBuffer(v)))return 1;
  const auto*r=prefix?GetSizePrefixedRoot(b.data()):GetRoot(b.data());
'''+checks+'\nreturn 0;}')
        (self.out/'CMakeLists.txt').write_text(f'''cmake_minimum_required(VERSION 3.20)
project(typed_verifier LANGUAGES CXX)
add_executable(verify_typed verify_typed.cpp)
target_include_directories(verify_typed PRIVATE "{source}/include")
target_compile_features(verify_typed PRIVATE cxx_std_17)
''')
        run('cmake','-S',self.out,'-B',self.out/'cpp')
        run('cmake','--build',self.out/'cpp','--config','Release')
        return self.out/'cpp'/'Release'/'verify_typed.exe' if os.name=='nt' else self.out/'cpp'/'verify_typed'

    def pair(self, schema, definitions, construct, checks, expected, extra='', views='', cpp_checks=''):
        oracle=self.out/'oracle.fbs'
        oracle.write_text(schema+'\nroot_type Root;\nfile_identifier "EXTD";\n')
        run(FLATC, '-c', '-b', '--schema', '--bfbs-builtins', '-o', self.out, oracle)
        typed=self.typed_verifier(cpp_checks) if 'vector64' in schema or 'union ' in schema else None
        das(ROOT/'tools/generate.das', self.out/'oracle.bfbs', self.out/'generated.das', self.out/'normalized.fbs')
        (self.out/'input.json').write_text(json.dumps(expected,ensure_ascii=True))
        run(FLATC,'-c','-b','--strict-json','-o',self.out,oracle,self.out/'input.json')
        for mode in ('macro','bfbs'):
            with self.subTest(mode=mode):
                header='require ../src/annotations.das\n'+definitions if mode=='macro' else 'require ./generated.das'
                body=header+'\nrequire daslib/fio\n'+extra+'''
[generic]
def check(value:auto(T)) {
CHECKS
}
[export]
def main {
    let args <- get_command_line_arguments()
    let directory=args[length(args)-1]
    var obj=Root()
CONSTRUCT
    let bytes <- fb_pack_Root(obj)
    verify(fb_verify_Root(bytes))
    let value <- fb_unpack_Root(bytes)
    check(value)
    let foreign_bytes <- fb_load(directory+"/input.bin")
    verify(fb_verify_Root(foreign_bytes))
    let foreign <- fb_unpack_Root(foreign_bytes)
    check(foreign)
    fb_save(directory+"/MODE.bin",bytes)
    fb_save(directory+"/MODE_repacked.bin",fb_pack_Root(foreign))
    let prefixed <- fb_pack_size_prefixed_Root(obj)
    let prefixed_value <- fb_unpack_size_prefixed_Root(prefixed)
    check(prefixed_value)
    let schema <- fb_schema_ir_Root()
    verify(fb_verify(prefixed,schema,"Root",true))
    fb_save(directory+"/MODE_size.bin",prefixed)
    let view=fb_view_Root(bytes)
VIEWS
    verify(fwrite(directory+"/MODE.fbs",fb_schema_Root()))
}
'''
                body=body.replace('CHECKS',checks).replace('CONSTRUCT',construct).replace('VIEWS',views).replace('MODE',mode)
                das(self.script('consume_'+mode,body),self.out.as_posix())
                for suffix in ('','_repacked'):
                    path=self.out/f'{mode}{suffix}.bin'
                    # flatc's JSON emitter cannot print Vector64 in this version.
                    # For it, typed official C++ getters check the values instead.
                    if 'vector64' not in schema:
                        run(FLATC,'-c','-t','--strict-json','--defaults-json','-o',self.out,oracle,'--',path)
                        self.assertEqual(json.loads(path.with_suffix('.json').read_text()),expected)
                    if typed:
                        run(typed,path)
                    elif OPTIONS.cpp_verifier:
                        run(OPTIONS.cpp_verifier,self.out/'oracle.bfbs',path)
                if typed:
                    run(typed,self.out/f'{mode}_size.bin','--size-prefixed')
                elif OPTIONS.cpp_verifier:
                    run(OPTIONS.cpp_verifier,self.out/'oracle.bfbs',self.out/f'{mode}_size.bin','--size-prefixed')
                run(FLATC,'-c','-b','--schema','-o',self.out,self.out/f'{mode}.fbs')

    def test_01_nullable_types_and_fixed_arrays(self):
        self.pair('''enum Color:byte { Red=1, Blue=2 }
struct Vec { x:float; y:int; }
struct Matrix { values:[float:3]; points:[Vec:2]; }
table Root { number:int=null; color:Color=null; text:string; names:[string]; matrix:Matrix; }''','''
[fb_enum]
enum Color:int8 { Red=1
Blue=2 }
[fb_struct]
struct Vec { x:float; y:int }
[fb_struct]
struct Matrix { values:float[3]; points:Vec[2] }
[fb_table(root=true,identifier="EXTD")]
struct Root {
@fb_id=0
number:Option<int>
@fb_id=1
color:Option<Color>
@fb_id=2
text:Option<string>
@fb_id=3
names:Option<array<string>>
@fb_id=4
matrix:Option<Matrix>
}''','''
obj.number <- some(0)
obj.color <- some(Color.Blue)
obj.text <- some("")
obj.names <- some(["hello","","こんにちは"])
var matrix:Matrix
matrix.values[2]=1.5
matrix.points[1].y=42
obj.matrix <- some(matrix)
''','''
assert(value.number is some && (value.number as some)==0)
assert(value.color is some && (value.color as some)==Color.Blue)
assert(value.text is some && empty(value.text as some))
assert((value.names as some)[2]=="こんにちは")
assert((value.matrix as some).values[2]==1.5 && (value.matrix as some).points[1].y==42)
''',{'number':0,'color':'Blue','text':'','names':['hello','','こんにちは'],
     'matrix':{'values':[0,0,1.5],'points':[{'x':0,'y':0},{'x':0,'y':42}]}},views='''
let scalar=fb_view_field(bytes,schema,view,0)
verify(scalar.present && fb_view_scalar(bytes,scalar,0)==0)
let names=fb_view_field(bytes,schema,view,3)
let text=fb_view_element(bytes,schema,names,0)
verify(text.count==5 && fb_view_byte(bytes,text,0)==uint8(104))
let absent <- fb_unpack_Root(fb_pack_Root(Root()))
assert(absent.number is none && absent.color is none && absent.matrix is none && absent.names is none)
''')

    def test_02_unions_and_vectors(self):
        self.pair('''table Weapon { power:int=7; }
struct Point { x:float; }
union Any { weapon:Weapon=2, point:Point=5, text:string=9 }
table Root { item:Any; items:[Any]; }''','''
[fb_table]
struct Weapon { @fb_id=0
power:int=7 }
[fb_struct]
struct Point { x:float }
typedef NativeUnion=variant<none;weapon:Weapon;point:Point;text:string>
[fb_table(root=true,identifier="EXTD")]
struct Root {
@fb_id=1
@fb_union="Any"
@fb_union_values="0,2,5,9"
item:NativeUnion
@fb_id=3
@fb_union="Any"
@fb_union_values="0,2,5,9"
items:Option<array<NativeUnion>>
}''','''obj.item=TestUnion(weapon=Weapon(power=42))
var items:array<TestUnion>
push(items,TestUnion(text="hi"))
push(items,TestUnion(point=Point(x=3.5)))
obj.items <- move_some(items)
''','''assert(value.item is weapon && (value.item as weapon).power==42)
assert((value.items as some)[0] is text && ((value.items as some)[0] as text)=="hi")
assert((value.items as some)[1] is point && ((value.items as some)[1] as point).x==3.5)
''',{'item_type':'weapon','item':{'power':42},
 'items_type':['text','point'],'items':['hi',{'x':3.5}]},
 extra='typedef TestUnion=variant<none;weapon:Weapon;point:Point;text:string>',views='''
let union_view=fb_view_field(bytes,schema,view,1)
verify(fb_view_scalar(bytes,fb_view_field(bytes,schema,union_view,0),0)==42)
''')

    def test_03_recursive_references(self):
        self.pair('table Root { value:int; next:Root; }','''
[fb_table(root=true,identifier="EXTD")]
struct Root { @fb_id=0
value:int
@fb_id=1
next:FBRef<Root> }
''','''obj.value=1
var child=Root(value=2)
child.next <- fb_ref(Root(value=3))
obj.next <- fb_move_ref(child)''','''assert(value.value==1 && value.next.value[0].value==2)
assert(value.next.value[0].next.value[0].value==3)
assert(empty(value.next.value[0].next.value[0].next.value))''',{'value':1,'next':{'value':2,'next':{'value':3}}})

    def test_04_wide_offsets(self):
        self.pair('''struct Point { x:double; y:int; }
table Root { text:string(offset64); numbers:[double](vector64); points:[Point](offset64); }''','''
[fb_struct]
struct Point { x:double; y:int }
[fb_table(root=true,identifier="EXTD")]
struct Root {
@fb_id=0
@fb_offset64
text:Option<string>
@fb_id=1
@fb_vector64
numbers:Option<array<double>>
@fb_id=2
@fb_offset64
points:Option<array<Point>>
}''','''obj.text <- some("wide")
obj.numbers <- some([1.5lf,2.25lf])
obj.points <- some([Point(x=3.5lf,y=7)])''','''assert((value.text as some)=="wide")
assert((value.numbers as some)[1]==2.25lf)
assert((value.points as some)[0].y==7)''',{'text':'wide','numbers':[1.5,2.25],'points':[{'x':3.5,'y':7}]},cpp_checks='''
if(!r->text() || r->text()->str()!="wide")return 3;
if(!r->numbers() || r->numbers()->size()!=2 || r->numbers()->Get(1)!=2.25)return 4;
if(!r->points() || r->points()->size()!=1 || r->points()->Get(0)->y()!=7)return 5;
''')

    def test_05_keys_sort_lookup_and_vtables(self):
        self.pair('table Item { id:int(key); value:int=7; } table Root { items:[Item]; }','''
[fb_table]
struct Item { @fb_id=0
@fb_key
id:int
@fb_id=1
value:int=7 }
[fb_table(root=true,identifier="EXTD")]
struct Root { @fb_id=0
items:Option<array<Item>> }
''','''var items <- [Item(id=3),Item(id=1),Item(id=2)]
fb_sort_Item(items)
obj.items <- move_some(items)''','''assert((value.items as some)[0].id==1 && (value.items as some)[2].id==3)''',
 {'items':[{'id':1,'value':7},{'id':2,'value':7},{'id':3,'value':7}]},views='''
let item_views=fb_view_field(bytes,schema,view,0)
verify(fb_lookup_key(bytes,schema,item_views,0,2)==1)
verify(fb_lookup_key(bytes,schema,item_views,0,9)==-1)
let first=fb_view_element(bytes,schema,item_views,0)
let second=fb_view_element(bytes,schema,item_views,1)
verify(fb_field(bytes,first.position,1,4)==0)
let vt1=first.position-int(fb_uint(bytes,first.position,4))
let vt2=second.position-int(fb_uint(bytes,second.position,4))
assert(vt1==vt2)
''')

    def test_06_nested_buffers(self):
        self.pair('''table Child { value:int=7; }
table Root { blob:[ubyte](nested_flatbuffer:"Child"); }''','''
[fb_table]
struct Child { @fb_id=0
value:int=7 }
[fb_table(root=true,identifier="EXTD")]
struct Root { @fb_id=0
@fb_nested="Child"
blob:Option<array<uint8>> }
''','''obj.blob <- some(fb_pack_Child(Child(value=42)))''','''
let child <- fb_unpack_Child(value.blob as some)
assert(child.value==42)
''',{'blob':{'value':42}},views='''
let blob=fb_view_field(bytes,schema,view,0)
let child_view=fb_view_nested(bytes,schema,blob,"Child")
verify(fb_view_scalar(bytes,fb_view_field(bytes,schema,child_view,0),0)==42)
''')

    def test_07_nonfinite_defaults(self):
        oracle=self.out/'nonfinite.fbs'
        oracle.write_text('table Root { x:float=nan; y:double=inf; z:double=-inf; } root_type Root;')
        run(FLATC,'-b','--schema','-o',self.out,oracle)
        das(ROOT/'tools/generate.das',oracle.with_suffix('.bfbs'),self.out/'generated.das',self.out/'normalized.fbs')
        for mode in ('macro','bfbs'):
            header='require ./generated.das' if mode=='bfbs' else '''require ../src/annotations.das
[fb_table(root=true)]
struct Root {
@fb_id=0
@fb_default="nan"
x:float
@fb_id=1
@fb_default="inf"
y:double
@fb_id=2
@fb_default="-inf"
z:double
}'''
            src=self.script('nonfinite_'+mode,header+'''
require math
[export]
def main {
    let bytes <- fb_pack_Root(Root())
    let value <- fb_unpack_Root(bytes)
    assert(value.x!=value.x && value.y>1e300lf && value.z < -1e300lf)
    verify(fb_verify_Root(bytes))
    let args <- get_command_line_arguments()
    fb_save(args[length(args)-1],bytes)
}
''')
            binary=self.out/f'{mode}.bin'
            das(src,binary)
            if OPTIONS.cpp_verifier:
                run(OPTIONS.cpp_verifier,oracle.with_suffix('.bfbs'),binary)

    def test_08_names_attributes_rpc_and_source_files(self):
        common=self.out/'common.fbs'
        common.write_text('''attribute "label";
namespace a_b;
table Thing { var:int; }
namespace a.b;
table Thing { value:int; }
namespace;
/// A response.
table Reply (label:"result") { value:int; }
''')
        oracle=self.out/'oracle.fbs'
        oracle.write_text('''include "common.fbs";
table Root { var:int (label:"field"); first:a_b.Thing; second:a.b.Thing; }
rpc_service Echo { Call(Root):Reply; }
root_type Root;
''')
        run(FLATC,'-b','--schema','--bfbs-builtins','--bfbs-comments','--bfbs-filenames',self.out,'-o',self.out,oracle)
        das(ROOT/'tools/generate.das',oracle.with_suffix('.bfbs'),self.out/'generated.das',self.out/'normalized.fbs')
        code=(self.out/'generated.das').read_text()
        self.assertIn('_fb_615f622e5468696e67',code)
        self.assertIn('a_b_Thing',code)
        self.assertIn('@fb_name="var"',code)
        self.assertIn('fb_rpc_Echo_Call',code)
        normalized=(self.out/'normalized.fbs').read_text()
        self.assertIn('label: "field"',normalized)
        self.assertIn('A response.',normalized)
        self.assertIn('rpc_service Echo',normalized)
        run(FLATC,'-b','--schema','-o',self.out,self.out/'normalized.fbs')
        client=self.script('rpc_client','''require ./generated.das
[export]
def main {
    var request=Root()
    request._fb_766172=42
    let reply <- fb_rpc_Echo_Call(request) $(method:string; payload:array<uint8>) : array<uint8> {
        assert(method=="Echo/Call")
        let decoded <- fb_unpack_Root(payload)
        assert(decoded._fb_766172==42)
        return <- fb_pack_Reply(Reply(value=43))
    }
    assert(reply.value==43)
}
''')
        das(client)
        restored=self.out/'restored'
        das(ROOT/'tools/restore_schema.das',oracle.with_suffix('.bfbs'),restored)
        self.assertTrue((restored/'oracle.fbs').exists())
        self.assertTrue((restored/'common.fbs').exists())
        run(FLATC,'-b','--schema','-o',restored,restored/'oracle.fbs')

    def test_09_verifier_mutations(self):
        oracle=self.out/'oracle.fbs'
        oracle.write_text('table Root { name:string; values:[int]; } root_type Root; file_identifier "FUZZ";')
        run(FLATC,'-b','--schema','-o',self.out,oracle)
        das(ROOT/'tools/generate.das',oracle.with_suffix('.bfbs'),self.out/'generated.das',self.out/'normalized.fbs')
        (self.out/'input.json').write_text('{"name":"hello","values":[1,2,3,4]}')
        run(FLATC,'-b','--strict-json','-o',self.out,oracle,self.out/'input.json')
        original=(self.out/'input.bin').read_bytes()
        rng=random.Random(1729)
        corpus=[original,b'',original[:4],original[:-1]]
        for _ in range(124):
            value=bytearray(original)
            for _ in range(rng.randint(1,3)):
                value[rng.randrange(len(value))]=rng.randrange(256)
            corpus.append(value)
        for i,value in enumerate(corpus):
            (self.out/f'fuzz_{i}.bin').write_bytes(value)
        check=self.script('fuzz','''require ./generated.das
[export]
def main {
    let args <- get_command_line_arguments()
    let folder=args[length(args)-1]
    for(i in range(128)){
        let bytes <- fb_load(folder+"/fuzz_{i}.bin")
        let valid=fb_verify_Root(bytes)
        print("{i}:{valid}\\n")
    }
}
''')
        output=das(check,self.out.as_posix())
        verdicts=dict(line.split(':') for line in output.splitlines() if ':' in line)
        self.assertEqual(len(verdicts),128)
        self.assertEqual(verdicts['0'],'true')
        self.assertEqual(verdicts['1'],'false')
        self.assertEqual(verdicts['2'],'false')
        if OPTIONS.cpp_verifier:
            for i,valid in verdicts.items():
                if valid=='true':
                    run(OPTIONS.cpp_verifier,oracle.with_suffix('.bfbs'),self.out/f'fuzz_{i}.bin')

    def test_11_recursive_union(self):
        self.pair('union Link { Root } table Root { value:int; next:Link; }','''
[fb_table(root=true,identifier="EXTD")]
struct Root {
@fb_id=0
value:int
@fb_id=2
@fb_union="Link"
next:variant<none; Root:FBRef<Root>>
}
''','''obj.value=1
obj.next <- TestLink(Root=fb_ref(Root(value=2)))''','''
assert(value.value==1)
assert(value.next is Root)
assert((value.next as Root).value[0].value==2)
assert((value.next as Root).value[0].next is none)
''',{'value':1,'next_type':'Root','next':{'value':2,'next_type':'NONE'}},
extra='typedef TestLink=variant<none; Root:FBRef<Root>>')

    def test_14_empty_vector_at_buffer_end(self):
        self.pair('table Root { values:[int]; }','''
[fb_table(root=true,identifier="EXTD")]
struct Root { @fb_id=0
values:Option<array<int>> }
''','''var values:array<int>
obj.values <- move_some(values)''','''
assert(value.values is some && empty(value.values as some))
''',{'values':[]})

    def test_13_mutual_required_reference(self):
        self.pair('table Root { child:Z; } table Z { back:Root(required); }','''
[fb_table]
struct Z { @fb_id=0
@fb_required
back:FBRef<Root> }
[fb_table(root=true,identifier="EXTD")]
struct Root { @fb_id=0
child:Option<Z> }
''','''var child=Z()
child.back <- fb_ref(Root())
obj.child <- move_some(child)''','''
assert(value.child is some)
assert(length((value.child as some).back.value)==1)
assert((value.child as some).back.value[0].child is none)
''',{'child':{'back':{}}})

    def test_12_code_first_service_ir(self):
        generator=self.script('service_ir','''require ../src/annotations.das
require ../src/bfbs.das
require daslib/fio
[fb_table(root=true)]
struct Request { @fb_id=0
value:int }
[fb_table]
struct Response { @fb_id=0
value:int }
[export]
def main {
    let args <- get_command_line_arguments()
    let folder=args[length(args)-1]
    var schema <- fb_schema_ir_Request()
    var response <- fb_descriptor_Response()
    emplace(schema.tables,response)
    var service=FBService(name="Echo")
    emplace(service.calls,FBRpcCall(name="Call",request="Request",response="Response"))
    emplace(schema.services,service)
    verify(fwrite(folder+"/service.fbs",fb_emit_schema(schema)))
    verify(fwrite(folder+"/service.das",fb_emit_das(schema,"service","../src/annotations.das")))
}
''')
        das(generator,self.out.as_posix())
        run(FLATC,'-b','--schema','-o',self.out,self.out/'service.fbs')
        das(self.script('service_client','''require ./service.das
[export]
def main {
    let result <- fb_rpc_Echo_Call(Request(value=4)) $(method:string; payload:array<uint8>):array<uint8> {
        assert(method=="Echo/Call")
        let request <- fb_unpack_Request(payload)
        return <- fb_pack_Response(Response(value=request.value+1))
    }
    assert(result.value==5)
}
'''))

    def test_10_flatc_backend(self):
        if not OPTIONS.flatc_das:
            self.skipTest('Pass --flatc-das to exercise the compiled backend')
        oracle=self.out/'backend.fbs'
        oracle.write_text('table Root { value:int=null; } root_type Root;')
        run(OPTIONS.flatc_das,'--dascript','-o',self.out,oracle)
        consumer=self.script('backend_client','''require ./backend_generated.das
[export]
def main {
    var value=Root()
    value.value <- some(0)
    let bytes <- fb_pack_Root(value)
    let decoded <- fb_unpack_Root(bytes)
    assert(decoded.value is some && (decoded.value as some)==0)
}
''')
        das(consumer)

if __name__=='__main__':
    unittest.main(argv=[__file__]+REST,verbosity=2)
