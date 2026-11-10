options gen2
options stack=262144
require ../src/annotations.das

[fb_struct]
struct Position { xyz:float[3] }

[fb_table]
struct Node {
    @fb_id=0
    @fb_key
    id:int
    @fb_id=1
    next:FBRef<Node>
}

typedef Payload=variant<none; node:Node; text:string>
[fb_table(root=true,identifier="ADVN")]
struct Record {
    @fb_id=0
    number:Option<int>
    @fb_id=1
    position:Option<Position>
    @fb_id=3
    @fb_union="Payload"
    payload:Payload
}

[export]
def main {
    var value=Record()
    value.number <- some(0) // present zero, different from none
    var node=Node(id=1)
    node.next <- fb_ref(Node(id=2))
    value.payload <- Payload(node <- node)
    let bytes <- fb_pack_Record(value)
    verify(fb_verify_Record(bytes))
    let decoded <- fb_unpack_Record(bytes)
    assert(decoded.number is some)
    assert(((decoded.payload as node).next.value[0]).id==2)
    let schema <- fb_schema_ir_Record()
    let root=fb_view_Record(bytes)
    let number=fb_view_field(bytes,schema,root,0)
    assert(number.present)
    verify(fb_view_scalar(bytes,number,0)==0)
    print(fb_schema_Record())
}
