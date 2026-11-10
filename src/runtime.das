options gen2
module runtime public
require strings
require daslib/fio

// Bounds-checked little-endian primitives; never cast unaligned byte pointers.
def fb_bounds(b : array<uint8>; p, n : int) {
    if (p < 0 || n < 0 || p > length(b) || n > length(b) - p) { panic("FlatBuffers: truncated or invalid buffer") }
}
def fb_uint(b : array<uint8>; p, n : int) : uint64 {
    fb_bounds(b, p, n)
    var v = 0ul
    for (i in range(n)) { v |= uint64(b[p+i]) << uint64(i*8) }
    return v
}
def fb_put(var b : array<uint8>; p, n : int; v : uint64) {
    fb_bounds(b, p, n)
    for (i in range(n)) { b[p+i] = uint8(v >> uint64(i*8)) }
}
def fb_offset(b : array<uint8>; p : int) : int {
    let off = fb_uint(b, p, 4)
    if (off < 4ul || off > uint64(length(b) - p)) { panic("FlatBuffers: invalid offset") }
    return p + int(off)
}
def fb_root(b : array<uint8>; identifier : string) : int {
    if (!empty(identifier)) {
        fb_bounds(b, 4, 4)
        var i = 0
        peek_data(identifier) $(bytes) {
            for (c in bytes) {
                if (b[4+i] != c) { panic("FlatBuffers: wrong file identifier") }
                i++
            }
        }
    }
    let root = fb_offset(b, 0)
    // Validate even empty tables, whose generated reader has no field calls.
    fb_field(b, root, 0, 0)
    return root
}
def fb_field(b : array<uint8>; root, id, width : int) : int {
    fb_bounds(b, root, 4)
    let delta = int64(int(fb_uint(b, root, 4)))
    let vt64 = int64(root) - delta
    if (vt64 < 0l || vt64 > int64(length(b)) - 4l) { panic("FlatBuffers: invalid vtable") }
    let vt = int(vt64)
    let size = int(fb_uint(b, vt, 2))
    let object_size = int(fb_uint(b, vt+2, 2))
    if (size < 4 || (size & 1) != 0 || object_size < 4) { panic("FlatBuffers: invalid table size") }
    fb_bounds(b, vt, size)
    fb_bounds(b, root, object_size)
    let slot = 4 + id*2
    if (slot >= size) { return 0 }
    let off = int(fb_uint(b, vt+slot, 2))
    if (off == 0) { return 0 }
    if (off < 4 || width > object_size - off) { panic("FlatBuffers: field outside table") }
    return root + off
}
def fb_string_at(b : array<uint8>; p : int) : string {
    let count = fb_uint(b, p, 4)
    if (count > uint64(length(b))) { panic("FlatBuffers: invalid string length") }
    fb_bounds(b, p+4, int(count)+1)
    if (b[p+4+int(count)] != 0u) { panic("FlatBuffers: string missing terminator") }
    var bytes : array<uint8>
    for (i in range(int(count))) { push(bytes, b[p+4+i]) }
    return string(bytes)
}
def fb_load(path : string) : array<uint8> {
    var b : array<uint8>
    fopen(path, "rb") $(f) {
        if (f == null) { panic("cannot open {path}") }
        fseek(f, 0l, 2)
        let sz = int(ftell(f))
        fseek(f, 0l, 0)
        resize(b, sz)
        if (sz > 0 && fread(f, b) != sz) { panic("short read: {path}") }
    }
    return <- b
}
def fb_save(path : string; b : array<uint8>) {
    fopen(path, "wb") $(f) {
        if (f == null) { panic("cannot write {path}") }
        if (!empty(b) && fwrite(f, b) != length(b)) { panic("short write: {path}") }
    }
}

struct FBBuilder {
    slots:array<int>
    vtables:array<int>
    object_size:int
    bytes : array<uint8>
    root : int
    vtable : int
    offsets : array<int>
}
def fb_align(var b : array<uint8>; alignment : int) {
    while ((length(b) % alignment) != 0) { push(b, 0u8) }
}
def fb_begin(count : int; identifier : string) : FBBuilder {
    if (count < 0 || count > 4094 || (!empty(identifier) && length(identifier) != 4)) {
        panic("FlatBuffers: invalid builder parameters")
    }
    var b : FBBuilder
    resize(b.bytes, empty(identifier) ? 4 : 8)
    if (!empty(identifier)) {
        var i = 4
        peek_data(identifier) $(chars) {
            for (c in chars) { b.bytes[i] = c; i++ }
        }
    }
    b.vtable = length(b.bytes)
    resize(b.bytes, length(b.bytes) + 4 + count*2)
    fb_put(b.bytes, b.vtable, 2, uint64(4+count*2))
    fb_put(b.bytes, b.vtable+2, 2, uint64(8+count*8))
    fb_align(b.bytes, 8)
    b.root = length(b.bytes)
    resize(b.bytes, b.root + 8 + count*8)
    fb_put(b.bytes, 0, 4, uint64(b.root))
    fb_put(b.bytes, b.root, 4, uint64(b.root-b.vtable))
    return <- b
}
def fb_slot(var b : FBBuilder; id : int) : int {
    if(b.vtable<0){
        if(id<0 || id>=length(b.offsets)){panic("FlatBuffers: invalid field id")}
        b.slots[id]=b.offsets[id]
        return b.root+b.offsets[id]
    }
    let count = (int(fb_uint(b.bytes, b.vtable, 2))-4)/2
    if (id < 0 || id >= count) { panic("FlatBuffers: invalid field id") }
    let off = empty(b.offsets) ? 8+id*8 : b.offsets[id]
    fb_put(b.bytes, b.vtable+4+id*2, 2, uint64(off))
    return b.root+off
}

def fb_check_reference(count : int) { if (count > 1) { panic("FlatBuffers: FBRef must have zero or one value") } }
def fb_write_nested(var b:FBBuilder; id:int; bytes:array<uint8>; alignment:int){
    let slot=fb_slot(b,id)
    fb_align(b.bytes,4)
    while((length(b.bytes)+4)%alignment!=0){push(b.bytes,0u8)}
    let p=length(b.bytes)
    resize(b.bytes,p+4+length(bytes))
    fb_put(b.bytes,p,4,uint64(length(bytes)))
    fb_copy_inline(b.bytes,p+4,bytes)
    fb_put(b.bytes,slot,4,uint64(p-slot))
}
def fb_depth(depth : int) {
    if (depth > 64) { panic("FlatBuffers: object nesting exceeds 64") }
}
def fb_begin_layout(offsets : array<int>; object_size, alignment : int; identifier : string) : FBBuilder {
    var b : FBBuilder
    b.offsets := offsets
    resize(b.bytes, empty(identifier) ? 4 : 8)
    if (!empty(identifier)) {
        var i = 4
        peek_data(identifier) $(chars) { for (c in chars) { b.bytes[i] = c; i++ } }
    }
    b.vtable = length(b.bytes)
    resize(b.bytes, length(b.bytes)+4+length(offsets)*2)
    fb_put(b.bytes, b.vtable, 2, uint64(4+length(offsets)*2))
    fb_put(b.bytes, b.vtable+2, 2, uint64(object_size))
    fb_align(b.bytes, alignment)
    b.root = length(b.bytes)
    resize(b.bytes, b.root+object_size)
    fb_put(b.bytes, 0, 4, uint64(b.root))
    fb_put(b.bytes, b.root, 4, uint64(b.root-b.vtable))
    return <- b
}
def fb_copy_inline(var b : array<uint8>; p : int; bytes : array<uint8>) {
    fb_bounds(b, p, length(bytes))
    for (i in range(length(bytes))) { b[p+i] = bytes[i] }
}
[generic]
def fb_write_inline(var b : array<uint8>; p : int; value : auto(T)) {
    fb_put(b, p, typeinfo sizeof(type<T>), fb_bits(value))
}
[generic]
def fb_read_inline(b : array<uint8>; p : int; var value : auto(T)&) {
    value = fb_from_bits(fb_uint(b, p, typeinfo sizeof(type<T>)), value)
}
def fb_append_table(var b : array<uint8>; bytes : array<uint8>; alignment : int) : int {
    let root = fb_root(bytes, "")
    fb_align(b, alignment)
    let start = length(b)
    if (length(bytes) > 2147483647-start) { panic("FlatBuffers: buffer too large") }
    resize(b, start+length(bytes))
    fb_copy_inline(b, start, bytes)
    return start+root
}
def fb_write_object(var b : FBBuilder; id : int; bytes : array<uint8>; fixed : bool; alignment : int) {
    let slot = fb_slot(b, id)
    if (fixed) { fb_copy_inline(b.bytes, slot, bytes) }
    else {
        let p = fb_append_table(b.bytes, bytes, alignment)
        fb_put(b.bytes, slot, 4, uint64(p-slot))
    }
}
def fb_nested_position(b : array<uint8>; root, id : int; required : bool; inline_size : int) : int {
    let p = fb_field(b, root, id, inline_size == 0 ? 4 : inline_size)
    if (p == 0) {
        if (required) { panic("FlatBuffers: missing required object") }
        return 0
    }
    return inline_size == 0 ? fb_offset(b, p) : p
}
def fb_write_objects(var b : FBBuilder; id : int; items : array<array<uint8>>; stride, alignment : int; fixed : bool) {
    let slot = fb_slot(b, id)
    fb_align(b.bytes, 4)
    while ((length(b.bytes)+4) % alignment != 0) { push(b.bytes, 0u8) }
    let p = length(b.bytes)
    if (length(items) > (2147483647-p-4)/stride) { panic("FlatBuffers: vector too large") }
    resize(b.bytes, p+4+length(items)*stride)
    fb_put(b.bytes, p, 4, uint64(length(items)))
    fb_put(b.bytes, slot, 4, uint64(p-slot))
    for (i in range(length(items))) {
        let at = p+4+i*stride
        if (fixed) {
            if (length(items[i]) != stride) { panic("FlatBuffers: struct stride mismatch") }
            fb_copy_inline(b.bytes, at, items[i])
        } else {
            let child = fb_append_table(b.bytes, items[i], alignment)
            fb_put(b.bytes, at, 4, uint64(child-at))
        }
    }
}
def fb_object_positions(b : array<uint8>; root, id, stride : int; required, fixed : bool) : array<int> {
    var result : array<int>
    let p = fb_nested_position(b, root, id, required, 0)
    if (p == 0) { return <- result }
    let count = fb_uint(b, p, 4)
    if (stride <= 0 || count > uint64((length(b)-p-4)/stride)) { panic("FlatBuffers: invalid object vector length") }
    for (i in range(int(count))) {
        let at = p+4+i*stride
        push(result, fixed ? at : fb_offset(b, at))
    }
    return <- result
}
[generic]
def fb_bits(v : auto(T)) : uint64 {
    static_if (typeinfo stripped_typename(type<T>) == "bool") {
        return v ? 1ul : 0ul
    } static_elif (typeinfo is_float(type<T>)) {
        return uint64(unsafe(reinterpret<uint>(v)))
    } static_elif (typeinfo is_double(type<T>)) {
        return unsafe(reinterpret<uint64>(v))
    } else {
        return uint64(v)
    }
}
[generic]
def fb_from_bits(v : uint64; unused : auto(T)) : T {
    static_if (typeinfo is_enum(type<T>)) {
        static_if (typeinfo sizeof(type<T>) == 1) { return unsafe(reinterpret<T>(uint8(v))) }
        static_elif (typeinfo sizeof(type<T>) == 2) { return unsafe(reinterpret<T>(uint16(v))) }
        static_elif (typeinfo sizeof(type<T>) == 4) { return unsafe(reinterpret<T>(uint(v))) }
        else { return unsafe(reinterpret<T>(v)) }
    } static_elif (typeinfo stripped_typename(type<T>) == "bool") {
        return v != 0ul
    } static_elif (typeinfo is_float(type<T>)) {
        return unsafe(reinterpret<float>(uint(v)))
    } static_elif (typeinfo is_double(type<T>)) {
        return unsafe(reinterpret<double>(v))
    } else {
        return T(v)
    }
}
[generic]
def fb_write(var b : FBBuilder; id : int; v : auto(T)) {
    let p = fb_slot(b, id)
    fb_put(b.bytes, p, typeinfo sizeof(type<T>), fb_bits(v))
}
def fb_write(var b : FBBuilder; id : int; v : string) {
    let slot = fb_slot(b, id)
    fb_align(b.bytes, 4)
    let p = length(b.bytes)
    resize(b.bytes, p+4)
    fb_put(b.bytes, p, 4, uint64(length(v)))
    peek_data(v) $(bytes) {
        for (c in bytes) { push(b.bytes, c) }
    }
    push(b.bytes, 0u8)
    fb_put(b.bytes, slot, 4, uint64(p-slot))
}
// String vectors contain offsets, not native string handles.
def fb_write(var b : FBBuilder; id : int; v : array<string>) {
    let slot = fb_slot(b, id)
    fb_align(b.bytes, 4)
    let p = length(b.bytes)
    if (length(v) > (2147483647-p-4)/4) { panic("FlatBuffers: vector too large") }
    resize(b.bytes, p+4+length(v)*4)
    fb_put(b.bytes, p, 4, uint64(length(v)))
    fb_put(b.bytes, slot, 4, uint64(p-slot))
    for (i in range(length(v))) {
        fb_align(b.bytes, 4)
        let text = length(b.bytes)
        resize(b.bytes, text+4)
        fb_put(b.bytes, text, 4, uint64(length(v[i])))
        peek_data(v[i]) $(chars) { for (c in chars) { push(b.bytes, c) } }
        push(b.bytes, 0u8)
        fb_put(b.bytes, p+4+i*4, 4, uint64(text-(p+4+i*4)))
    }
}
def fb_read(b : array<uint8>; root, id : int; var value : array<string>; required : bool) {
    clear(value)
    let positions <- fb_object_positions(b, root, id, 4, required, false)
    for (at in positions) { push(value, fb_string_at(b, at)) }
}

// Prefix padding is placed before the root table, preserving all alignments.
def fb_size_prefixed(bytes : array<uint8>; alignment : int = 8; prefix_width:int=4) : array<uint8> {
    if (alignment < 4 || (alignment & (alignment-1)) != 0) { panic("FlatBuffers: invalid prefix alignment") }
    let root = fb_root(bytes, "")
    if(prefix_width!=4 && prefix_width!=8){panic("FlatBuffers: invalid prefix width")}
    let shift=((prefix_width+alignment-1)/alignment)*alignment
    var result : array<uint8>
    resize(result, length(bytes)+shift)
    fb_copy_inline(result, shift, bytes)
    fb_put(result, 0, prefix_width, uint64(length(result)-prefix_width))
    fb_put(result, prefix_width, 4, uint64(root+shift-prefix_width))
    // Header bytes beyond the root offset contain the identifier, when present.
    if (length(bytes) >= 8) { for (i in range(4)) { result[prefix_width+4+i] = bytes[4+i] } }
    return <- result
}
def fb_size_root(bytes : array<uint8>; identifier : string; prefix_width:int=4) : int {
    if(prefix_width!=4 && prefix_width!=8){panic("FlatBuffers: invalid prefix width")}
    if (fb_uint(bytes, 0, prefix_width) != uint64(length(bytes)-prefix_width)) { panic("FlatBuffers: size prefix mismatch") }
    if (!empty(identifier)) {
        fb_bounds(bytes, prefix_width+4, 4)
        var i = 0
        peek_data(identifier) $(chars) { for (c in chars) {
            if (bytes[prefix_width+4+i] != c) { panic("FlatBuffers: wrong file identifier") }; i++
        } }
    }
    let root = fb_offset(bytes, prefix_width)
    fb_field(bytes, root, 0, 0)
    return root
}
[generic]
def fb_write(var b : FBBuilder; id : int; v : array<auto(T)>) {
    let slot = fb_slot(b, id)
    let width = typeinfo sizeof(type<T>)
    fb_align(b.bytes, 4)
    while (((length(b.bytes)+4) % width) != 0) { push(b.bytes, 0u8) }
    let p = length(b.bytes)
    if (length(v) > (2147483647-p-4)/width) { panic("FlatBuffers: vector too large") }
    resize(b.bytes, p+4+length(v)*width)
    fb_put(b.bytes, p, 4, uint64(length(v)))
    for (i in range(length(v))) { fb_put(b.bytes, p+4+i*width, width, fb_bits(v[i])) }
    fb_put(b.bytes, slot, 4, uint64(p-slot))
}
[generic]
def fb_read(b : array<uint8>; root, id : int; var value : auto(T)&; required : bool) {
    let p = fb_field(b, root, id, typeinfo sizeof(type<T>))
    if (p != 0) { value = fb_from_bits(fb_uint(b, p, typeinfo sizeof(type<T>)), value) }
}
def fb_read(b : array<uint8>; root, id : int; var value : string&; required : bool) {
    let p = fb_field(b, root, id, 4)
    if (p == 0) {
        if (required) { panic("FlatBuffers: missing required string") }
        value = ""
    } else {
        value = fb_string_at(b, fb_offset(b, p))
    }
}
[generic]
def fb_read(b : array<uint8>; root, id : int; var value : array<auto(T)>; required : bool) {
    clear(value)
    let slot = fb_field(b, root, id, 4)
    if (slot == 0) {
        if (required) { panic("FlatBuffers: missing required vector") }
        return
    }
    let p = fb_offset(b, slot)
    let n = fb_uint(b, p, 4)
    let width = typeinfo sizeof(type<T>)
    if (n > uint64((length(b)-p-4)/width)) { panic("FlatBuffers: invalid vector length") }
    resize(value, int(n))
    for (i in range(int(n))) { value[i] = fb_from_bits(fb_uint(b, p+4+i*width, width), value[i]) }
}







struct FBUnionEncoded {
    position:int
    tag : uint8
    kind : int
    bytes : array<uint8>
}
struct FBUnionLocation { tag:uint8; position:int }
def fb_encode_string(value:string) : array<uint8> {
    var bytes : array<uint8>
    resize(bytes,4)
    fb_put(bytes,0,4,uint64(length(value)))
    peek_data(value) $(chars) { for (c in chars) { push(bytes,c) } }
    push(bytes,0u8)
    return <- bytes
}
def fb_append_union(var b:array<uint8>; value:FBUnionEncoded; alignment:int) : int {
    if(value.position!=0){return value.position}
    if (value.kind == 15) { return fb_append_table(b,value.bytes,alignment) }
    fb_align(b,alignment)
    let p=length(b)
    resize(b,p+length(value.bytes))
    fb_copy_inline(b,p,value.bytes)
    return p
}
def fb_append_text(var bytes:array<uint8>; text:string) : int {
    fb_align(bytes,4)
    let p=length(bytes)
    resize(bytes,p+4)
    fb_put(bytes,p,4,uint64(length(text)))
    peek_data(text) $(chars){for(c in chars){push(bytes,c)}}
    push(bytes,0u8)
    return p
}
struct FBUnionSlots { tags:int; values:int; count:int }
def fb_begin_unions(var b:FBBuilder; id,count:int) : FBUnionSlots {
    let tag_slot=fb_slot(b,id-1)
    fb_align(b.bytes,4)
    let tags=length(b.bytes)
    resize(b.bytes,tags+4+count)
    fb_put(b.bytes,tags,4,uint64(count))
    fb_put(b.bytes,tag_slot,4,uint64(tags-tag_slot))
    let values=fb_reserve_objects(b,id,count)
    return FBUnionSlots(tags=tags+4,values=values,count=count)
}
def fb_set_union(var b:FBBuilder; slots:FBUnionSlots; index:int; value:FBUnionEncoded; alignment:int){
    if(index<0 || index>=slots.count){panic("FlatBuffers: union index out of bounds")}
    b.bytes[slots.tags+index]=value.tag
    if(value.tag!=0u8){fb_set_object(b,slots.values+index*4,fb_append_union(b.bytes,value,alignment))}
}
def fb_write_union(var b:FBBuilder; id:int; value:FBUnionEncoded; alignment:int; required:bool) {
    if (value.tag==0u8) {
        if (required) { panic("FlatBuffers: required union is none") }
        return
    }
    fb_write(b,id-1,value.tag)
    let slot=fb_slot(b,id)
    let p=fb_append_union(b.bytes,value,alignment)
    fb_put(b.bytes,slot,4,uint64(p-slot))
}
def fb_union_location(b:array<uint8>; root,id:int; required:bool) : FBUnionLocation {
    var tag=0u8
    fb_read(b,root,id-1,tag,false)
    let slot=fb_field(b,root,id,4)
    if (tag==0u8) {
        if (required || (slot!=0 && fb_uint(b,slot,4)!=0ul)) { panic("FlatBuffers: invalid absent union") }
        return FBUnionLocation()
    }
    if (slot==0) { panic("FlatBuffers: union payload is missing") }
    return FBUnionLocation(tag=tag,position=fb_offset(b,slot))
}
def fb_write_unions(var b:FBBuilder; id:int; values:array<FBUnionEncoded>; alignment:int) {
    var tags:array<uint8>
    for (v in values) { push(tags,v.tag) }
    fb_write(b,id-1,tags)
    let slot=fb_slot(b,id)
    fb_align(b.bytes,4)
    let p=length(b.bytes)
    if (length(values)>(2147483647-p-4)/4) { panic("FlatBuffers: union vector too large") }
    resize(b.bytes,p+4+length(values)*4)
    fb_put(b.bytes,p,4,uint64(length(values)))
    fb_put(b.bytes,slot,4,uint64(p-slot))
    for (i in range(length(values))) {
        if (values[i].tag==0u8) { continue }
        let child=fb_append_union(b.bytes,values[i],alignment)
        fb_put(b.bytes,p+4+i*4,4,uint64(child-(p+4+i*4)))
    }
}
def fb_union_locations(b:array<uint8>; root,id:int; required:bool) : array<FBUnionLocation> {
    var result:array<FBUnionLocation>
    let tags=fb_nested_position(b,root,id-1,required,0)
    let values=fb_nested_position(b,root,id,required,0)
    if (tags==0 && values==0) { return <- result }
    if (tags==0 || values==0) { panic("FlatBuffers: incomplete union vector") }
    let count=fb_uint(b,tags,4)
    if (count!=fb_uint(b,values,4) || count>uint64((length(b)-values-4)/4)) { panic("FlatBuffers: union vector lengths differ") }
    fb_bounds(b,tags+4,int(count))
    for (i in range(int(count))) {
        let tag=b[tags+4+i]
        let slot=values+4+i*4
        if (tag==0u8 && fb_uint(b,slot,4)!=0ul) { panic("FlatBuffers: invalid NONE union element") }
        push(result,FBUnionLocation(tag=tag,position=tag==0u8 ? 0 : fb_offset(b,slot)))
    }
    return <- result
}

def fb_offset_width(b:array<uint8>; p,width:int) : int {
    let offset=fb_uint(b,p,width)
    if (offset<uint64(width) || offset>uint64(length(b)-p)) { panic("FlatBuffers: invalid wide offset") }
    return p+int(offset)
}
def fb_write_wide(var b:FBBuilder; id:int; value:string; vector64:bool) {
    let slot=fb_slot(b,id)
    fb_align(b.bytes,4)
    let p=length(b.bytes)
    let bytes <- fb_encode_string(value)
    resize(b.bytes,p+length(bytes))
    fb_copy_inline(b.bytes,p,bytes)
    fb_put(b.bytes,slot,8,uint64(p-slot))
}
def fb_read_wide(b:array<uint8>; root,id:int; var value:string&; required,vector64:bool) {
    let slot=fb_field(b,root,id,8)
    if (slot==0) { if(required){panic("FlatBuffers: missing required string")}; return }
    value=fb_string_at(b,fb_offset_width(b,slot,8))
}
[generic]
def fb_write_wide(var b:FBBuilder; id:int; value:array<auto(T)>; vector64:bool) {
    let slot=fb_slot(b,id)
    let header=vector64 ? 8 : 4
    let width=typeinfo sizeof(type<T>)
    fb_align(b.bytes,header)
    while ((length(b.bytes)+header)%width!=0) { push(b.bytes,0u8) }
    let p=length(b.bytes)
    if(length(value)>(2147483647-p-header)/width){panic("FlatBuffers: vector too large")}
    resize(b.bytes,p+header+length(value)*width)
    fb_put(b.bytes,p,header,uint64(length(value)))
    fb_put(b.bytes,slot,8,uint64(p-slot))
    for(i in range(length(value))){fb_put(b.bytes,p+header+i*width,width,fb_bits(value[i]))}
}
[generic]
def fb_read_wide(b:array<uint8>; root,id:int; var value:array<auto(T)>; required,vector64:bool) {
    clear(value)
    let slot=fb_field(b,root,id,8)
    if(slot==0){if(required){panic("FlatBuffers: missing required vector")};return}
    let p=fb_offset_width(b,slot,8)
    let header=vector64 ? 8 : 4
    let width=typeinfo sizeof(type<T>)
    let count=fb_uint(b,p,header)
    if(count>uint64((length(b)-p-header)/width)){panic("FlatBuffers: vector too large")}
    resize(value,int(count))
    for(i in range(int(count))){value[i]=fb_from_bits(fb_uint(b,p+header+i*width,width),value[i])}
}
def fb_write_wide_structs(var b:FBBuilder; id:int; items:array<array<uint8>>; stride,alignment:int; vector64:bool) {
    let slot=fb_slot(b,id)
    let header=vector64 ? 8 : 4
    fb_align(b.bytes,header)
    while((length(b.bytes)+header)%alignment!=0){push(b.bytes,0u8)}
    let p=length(b.bytes)
    if(length(items)>(2147483647-p-header)/stride){panic("FlatBuffers: vector too large")}
    resize(b.bytes,p+header+length(items)*stride)
    fb_put(b.bytes,p,header,uint64(length(items)))
    fb_put(b.bytes,slot,8,uint64(p-slot))
    for(i in range(length(items))){fb_copy_inline(b.bytes,p+header+i*stride,items[i])}
}
def fb_wide_struct_positions(b:array<uint8>; root,id,stride:int; required,vector64:bool) : array<int> {
    var positions:array<int>
    let slot=fb_field(b,root,id,8)
    if(slot==0){if(required){panic("FlatBuffers: missing required vector")};return <- positions}
    let p=fb_offset_width(b,slot,8)
    let header=vector64 ? 8 : 4
    let count=fb_uint(b,p,header)
    if(count>uint64((length(b)-p-header)/stride)){panic("FlatBuffers: vector too large")}
    for(i in range(int(count))){push(positions,p+header+i*stride)}
    return <- positions
}

struct FBFrame { root:int; vtable:int; offsets:array<int>; slots:array<int>; object_size:int }
def fb_enter(var b:FBBuilder; offsets:array<int>; size,alignment:int) : FBFrame {
    var previous=FBFrame(root=b.root,vtable=b.vtable,object_size=b.object_size)
    previous.offsets <- b.offsets
    previous.slots <- b.slots
    b.offsets := offsets
    resize(b.slots,length(offsets))
    b.object_size=size
    b.vtable=-1
    fb_align(b.bytes,alignment)
    b.root=length(b.bytes)
    resize(b.bytes,b.root+size)
    return <- previous
}
def fb_leave(var b:FBBuilder; var previous:FBFrame) : int {
    var count=length(b.slots)
    while(count>0 && b.slots[count-1]==0){count--}
    let size=4+count*2
    var vt=-1
    for(candidate in b.vtables){
        if(fb_uint(b.bytes,candidate,2)!=uint64(size) || fb_uint(b.bytes,candidate+2,2)!=uint64(b.object_size)){continue}
        var same=true
        for(i in range(count)){if(fb_uint(b.bytes,candidate+4+i*2,2)!=uint64(b.slots[i])){same=false;break}}
        if(same){vt=candidate;break}
    }
    if(vt<0){
        fb_align(b.bytes,2)
        vt=length(b.bytes)
        resize(b.bytes,vt+size)
        fb_put(b.bytes,vt,2,uint64(size))
        fb_put(b.bytes,vt+2,2,uint64(b.object_size))
        for(i in range(count)){fb_put(b.bytes,vt+4+i*2,2,uint64(b.slots[i]))}
        push(b.vtables,vt)
    }
    let root=b.root
    fb_put(b.bytes,root,4,uint64(int64(root-vt)))
    b.root=previous.root;b.vtable=previous.vtable;b.object_size=previous.object_size
    b.offsets <- previous.offsets
    b.slots <- previous.slots
    return root
}
def fb_header(identifier:string) : FBBuilder {
    var b:FBBuilder
    resize(b.bytes,empty(identifier) ? 4 : 8)
    if(!empty(identifier)){
        var i=4
        peek_data(identifier) $(chars){for(c in chars){b.bytes[i]=c;i++}}
    }
    return <- b
}
def fb_reference(var b:FBBuilder; id,target:int){
    let slot=fb_slot(b,id)
    if(target<=slot){panic("FlatBuffers: reference must point forward")}
    fb_put(b.bytes,slot,4,uint64(target-slot))
}
def fb_reserve_objects(var b:FBBuilder; id,count:int) : int {
    let slot=fb_slot(b,id)
    fb_align(b.bytes,4)
    let p=length(b.bytes)
    if(count>(2147483647-p-4)/4){panic("FlatBuffers: vector too large")}
    resize(b.bytes,p+4+count*4)
    fb_put(b.bytes,p,4,uint64(count))
    fb_put(b.bytes,slot,4,uint64(p-slot))
    return p+4
}
def fb_set_object(var b:FBBuilder; slot,target:int){
    if(target<=slot){panic("FlatBuffers: reference must point forward")}
    fb_put(b.bytes,slot,4,uint64(target-slot))
}
