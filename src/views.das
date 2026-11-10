options gen2
module views public
require strings
require ./ir.das public
require ./runtime.das public

// Views store offsets, never raw pointers or owned payloads. Pass the original
// immutable buffer to every accessor; keep it alive for the lifetime of the view.
struct FBView {
    present : bool
    kind : int
    element : int
    position : int
    count : int
    stride : int
    header : int
    object_index : int = -1
    enum_index : int = -1
    union_tags : int
    default_bits : uint64
}
def fb_view_root(data:array<uint8>; schema:FBSchema; type_name:string; size_prefixed:bool=false) : FBView {
    let index=fb_object_index(schema,type_name)
    if(index<0){panic("FlatBuffers: unknown root type")}
    if(schema.tables[index].is_struct){
        if(size_prefixed){panic("FlatBuffers: fixed structs do not have size-prefixed roots")}
        return FBView(present=true,kind=15,object_index=index,position=0)
    }
    let ident=schema.tables[index].identifier
    return FBView(present=true,kind=15,object_index=index,
        position=size_prefixed ? fb_size_root(data,ident,fb_prefix_width(schema)) : fb_root(data,ident))
}
def fb_default_bits(f:FBField) : uint64 {
    if(f.optional || empty(f.default_value) || f.default_value=="null"){return 0ul}
    if(f.kind==2){return f.default_value=="true" ? 1ul : 0ul}
    if(f.kind==11){return fb_bits(float(f.default_value))}
    if(f.kind==12){return fb_bits(double(f.default_value))}
    if(f.kind==4 || f.kind==6 || f.kind==8 || f.kind==10){return uint64(f.default_value)}
    return uint64(int64(f.default_value))
}
def fb_view_union(data:array<uint8>; schema:FBSchema; enum_index,tag,position:int) : FBView {
    if(enum_index<0){panic("FlatBuffers: missing union metadata")}
    for(member in schema.enums[enum_index].values){
        if(int(member.value)!=tag){continue}
        var result=FBView(present=tag!=0,kind=member.kind,position=position)
        if(member.kind==15){result.object_index=fb_object_index(schema,member.type_name)}
        if(member.kind==13){
            let count=fb_uint(data,position,4)
            if(count>uint64(length(data)-position-4)){panic("FlatBuffers: invalid string length")}
            result.count=int(count)
        }
        return result
    }
    panic("FlatBuffers: unknown union tag")
    return FBView()
}
def fb_view_field(data:array<uint8>; schema:FBSchema; parent:FBView; id:int) : FBView {
    if(!parent.present || parent.kind!=15 || parent.object_index<0){panic("FlatBuffers: field access needs an object view")}
    assume object=schema.tables[parent.object_index]
    for(f in object.fields){
        if(f.id!=id){continue}
        let width=fb_inline_size(schema,f)
        let slot=object.is_struct ? parent.position+f.offset : fb_field(data,parent.position,id,width)
        var result=FBView(present=slot!=0,kind=f.kind,element=f.element,position=slot)
        if(f.kind==15 || ((f.kind==14 || f.kind==17) && f.element==15)){result.object_index=fb_object_index(schema,f.type_name)}
        elif(!empty(f.type_name)){result.enum_index=fb_enum_index(schema,f.type_name)}
        if(f.kind==16){
            let location=fb_union_location(data,parent.position,id,f.required)
            return fb_view_union(data,schema,result.enum_index,int(location.tag),location.position)
        }
        if(slot==0){
            if(f.kind==14 && f.element==16 && fb_field(data,parent.position,id-1,4)!=0){panic("FlatBuffers: incomplete union vector")}
            if(f.required){panic("FlatBuffers: missing required field")}
            if(fb_scalar(f.kind)){result.default_bits=fb_default_bits(f)}
            return result
        }
        if(f.kind==13 || f.kind==14 || (f.kind==15 && !schema.tables[result.object_index].is_struct)){
            result.position=fb_offset_width(data,slot,f.offset64 ? 8 : 4)
        }
        if(f.kind==13 || f.kind==14){
            let header=f.vector64 ? 8 : 4
            let count=fb_uint(data,result.position,header)
            result.stride=f.kind==13 ? 1 : (f.element==15 ? (schema.tables[result.object_index].is_struct ? schema.tables[result.object_index].byte_size : 4) : fb_width(f.element))
            if(result.stride<=0 || count>uint64((length(data)-result.position-header)/result.stride)){panic("FlatBuffers: invalid view vector length")}
            result.count=int(count)
            if(f.kind==14){result.position+=header;result.header=header}
            if(f.kind==14 && f.element==16){
                result.union_tags=fb_nested_position(data,parent.position,id-1,f.required,0)
                if(result.union_tags==0 || fb_uint(data,result.union_tags,4)!=count){panic("FlatBuffers: union vector lengths differ")}
                result.union_tags+=4
                fb_bounds(data,result.union_tags,result.count)
            }
        } elif(f.kind==17){
            result.count=f.fixed_length
            result.stride=width/f.fixed_length
            fb_bounds(data,result.position,width)
        }
        return result
    }
    panic("FlatBuffers: unknown field id")
    return FBView()
}
def fb_view_nested(data:array<uint8>; schema:FBSchema; bytes:FBView; type_name:string) : FBView {
    if(!bytes.present || bytes.kind!=14 || bytes.element!=4 || bytes.count<4){panic("FlatBuffers: nested buffer requires a byte vector")}
    let index=fb_object_index(schema,type_name)
    if(index<0 || schema.tables[index].is_struct){panic("FlatBuffers: nested root requires a table")}
    let root=fb_offset(data,bytes.position)
    if(root>=bytes.position+bytes.count){panic("FlatBuffers: nested root outside byte vector")}
    return FBView(present=true,kind=15,position=root,object_index=index)
}
def fb_view_element(data:array<uint8>; schema:FBSchema; vector:FBView; index:int) : FBView {
    if(!vector.present || (vector.kind!=14 && vector.kind!=17) || index<0 || index>=vector.count){panic("FlatBuffers: view index out of bounds")}
    let slot=vector.position+index*vector.stride
    var result=FBView(present=true,kind=vector.element,position=slot,object_index=vector.object_index,enum_index=vector.enum_index)
    if(vector.element==16){
        let tag=int(data[vector.union_tags+index])
        if(tag==0 && fb_uint(data,slot,4)!=0ul){panic("FlatBuffers: invalid NONE union element")}
        return fb_view_union(data,schema,vector.enum_index,tag,tag==0 ? 0 : fb_offset(data,slot))
    }
    if(result.kind==13 || (result.kind==15 && !schema.tables[result.object_index].is_struct)){result.position=fb_offset(data,slot)}
    if(result.kind==13){
        let count=fb_uint(data,result.position,4)
        if(count>uint64(length(data)-result.position-4)){panic("FlatBuffers: invalid string length")}
        result.count=int(count)
    }
    return result
}
[generic]
def fb_view_scalar(data:array<uint8>; view:FBView; witness:auto(T)) : T {
    if(!fb_scalar(view.kind) && view.kind!=1){panic("FlatBuffers: scalar view required")}
    if(typeinfo sizeof(type<T>)!=fb_width(view.kind)){panic("FlatBuffers: scalar view type width mismatch")}
    return fb_from_bits(view.present ? fb_uint(data,view.position,fb_width(view.kind)) : view.default_bits,witness)
}
def fb_view_string(data:array<uint8>; view:FBView) : string {
    if(view.kind!=13){panic("FlatBuffers: string view required")}
    return view.present ? fb_string_at(data,view.position) : ""
}
def fb_view_byte(data:array<uint8>; view:FBView; index:int) : uint8 {
    if(!view.present || view.kind!=13 || index<0 || index>=view.count){panic("FlatBuffers: string view index out of bounds")}
    fb_bounds(data,view.position+4+index,1)
    return data[view.position+4+index]
}
[generic]
def fb_lookup_key(data:array<uint8>; schema:FBSchema; vector:FBView; key_id:int; key:auto(T)) : int {
    var low=0
    var high=vector.count
    while(low<high){
        let mid=low+(high-low)/2
        let field=fb_view_field(data,schema,fb_view_element(data,schema,vector,mid),key_id)
        static_if(typeinfo stripped_typename(type<T>)=="string"){
            let value=fb_view_string(data,field)
            if(value<key){low=mid+1}else{high=mid}
        } else {
            let value=fb_view_scalar(data,field,key)
            if(value<key){low=mid+1}else{high=mid}
        }
    }
    if(low==vector.count){return -1}
    let field=fb_view_field(data,schema,fb_view_element(data,schema,vector,low),key_id)
    static_if(typeinfo stripped_typename(type<T>)=="string"){return fb_view_string(data,field)==key ? low : -1}
    else{return fb_view_scalar(data,field,key)==key ? low : -1}
}
