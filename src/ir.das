options gen2
module ir public
require strings
require math
require daslib/strings_boost

// Type tags deliberately match reflection.fbs. No compiler AST dependencies.
struct FBAttribute { name:string; value:string }
struct FBField {
    attributes:array<FBAttribute>
    documentation:array<string>
    union_values:string
    union_names:string
    name : string
    id : int
    kind : int
    element : int
    default_value : string
    deprecated : bool
    required : bool
    optional_table : bool // compatibility flag for Option<Table>
    boxed : bool // FBRef<T>, owning indirection for recursive tables
    optional : bool // native presence, including scalar = null
    fixed_length : int
    key : bool
    native_name : string // empty means name; native spelling may differ from wire
    nested_buffer : string
    offset64 : bool
    vector64 : bool
    type_name : string // qualified object/enum name; also used for vector elements
    offset : int
    padding : int
}
struct FBTable {
    attributes:array<FBAttribute>
    documentation:array<string>
    declaration_file:string
    name : string
    name_space : string
    identifier : string
    is_root : bool
    fields : array<FBField>
    is_struct : bool
    alignment : int
    byte_size : int
    force_align : int
}
struct FBEnumValue {
    boxed:bool
    kind : int
    type_name : string
    name : string
    value : string
}
struct FBEnum {
    attributes:array<FBAttribute>
    documentation:array<string>
    declaration_file:string
    is_union : bool
    name : string
    name_space : string
    underlying : int
    values : array<FBEnumValue>
}
struct FBRpcCall { name:string; request:string; response:string; attributes:array<FBAttribute>; documentation:array<string> }
struct FBService { name:string; calls:array<FBRpcCall>; attributes:array<FBAttribute>; documentation:array<string>; declaration_file:string }
struct FBSource { filename:string; includes:array<string> }
struct FBSchema {
    services:array<FBService>
    sources:array<FBSource>
    file_extension:string
    tables : array<FBTable>
    enums : array<FBEnum>
}

def fb_builtin_attribute(name:string) : bool {
    let names=["deprecated","required","key","shared","hash","id","force_align","bit_flags","original_order","nested_flatbuffer","csharp_partial","streaming","idempotent","cpp_type","cpp_ptr_type","cpp_ptr_type_get","cpp_str_type","cpp_str_flex_ctor","native_inline","native_custom_alloc","native_type","native_type_pack_name","native_default","flexbuffer","private","offset64","vector64"]
    for(item in names){if(item==name){return true}}
    return false
}
def fb_quote(s:string) : string => "\"" + replace(replace(replace(replace(s,"\\","\\\\"),"\"","\\\""),"\n","\\n"),"\r","\\r") + "\""
def fb_attributes(attrs:array<FBAttribute>; leading:bool) : string {
    var result=""
    var comma=leading
    for(a in attrs){
        if(!fb_identifier(a.name)){panic("invalid attribute name")}
        result+=comma ? ", " : ""
        result+=a.name
        if(!empty(a.value)){result+=": "+fb_quote(a.value)}
        comma=true
    }
    return result
}
def fb_docs(lines:array<string>; indent:string="") : string {
    var result=""
    for(line in lines){for(part in split(line,"\n")){result+=indent+"/// "+part+"\n"}}
    return result
}
def fb_qualified(ns, name : string) : string => empty(ns) ? name : "{ns}.{name}"
def fb_object_index(s : FBSchema; name : string) : int {
    for (i in range(length(s.tables))) {
        if (fb_qualified(s.tables[i].name_space, s.tables[i].name) == name) { return i }
    }
    return -1
}
def fb_enum_index(s : FBSchema; name : string) : int {
    for (i in range(length(s.enums))) {
        if (fb_qualified(s.enums[i].name_space, s.enums[i].name) == name) { return i }
    }
    return -1
}
def fb_round_up(n, align : int) : int => ((n+align-1)/align)*align

def fb_inline_size(s : FBSchema; f : FBField) : int {
    if (f.kind == 17) {
        var element := f
        element.kind = f.element
        element.fixed_length = 0
        return fb_inline_size(s, element) * f.fixed_length
    }
    if (f.offset64) { return 8 }
    if (f.kind == 15) {
        let i = fb_object_index(s, f.type_name)
        if (i < 0) { panic("unknown object: {f.type_name}") }
        return s.tables[i].is_struct ? s.tables[i].byte_size : 4
    }
    return fb_width(f.kind)
}
def fb_inline_alignment(s : FBSchema; f : FBField) : int {
    if (f.kind == 17) {
        var element := f
        element.kind = f.element
        element.fixed_length = 0
        return fb_inline_alignment(s, element)
    }
    if (f.offset64) { return 8 }
    if (f.kind == 15) {
        let i = fb_object_index(s, f.type_name)
        if (i < 0) { panic("unknown object: {f.type_name}") }
        return s.tables[i].is_struct ? s.tables[i].alignment : 4
    }
    return fb_width(f.kind)
}
def fb_layout(var s : FBSchema; index : int; var states : array<int>) {
    if (states[index] == 2) { return }
    if (states[index] == 1) { panic("cyclic inline struct layout") }
    states[index] = 1
    // Work on a clone: recursive traversal must not borrow an array element.
    var t := s.tables[index]
    for (f in t.fields) {
        if(!empty(f.nested_buffer)){
            if(f.kind!=14 || f.element!=4 || f.offset64){panic("nested_flatbuffer requires a 32-bit byte vector")}
            var nested=fb_object_index(s,f.nested_buffer)
            if(nested<0){nested=fb_object_index(s,fb_qualified(t.name_space,f.nested_buffer))}
            if(nested<0 || s.tables[nested].is_struct){panic("unknown nested_flatbuffer table")}
            f.nested_buffer=fb_qualified(s.tables[nested].name_space,s.tables[nested].name)
        }
        if (f.kind == 15 || ((f.kind == 14 || f.kind == 17) && f.element == 15)) {
            let dep = fb_object_index(s, f.type_name)
            if (dep < 0) { panic("unknown object: {f.type_name}") }

            if (f.offset64 && !s.tables[dep].is_struct) { panic("offset64 object vectors require fixed structs") }
            if (t.is_struct && !s.tables[dep].is_struct) { panic("fixed struct cannot contain a table: {t.name}.{f.name}") }
            if (s.tables[dep].is_struct) { fb_layout(s, dep, states) }
        } elif (!empty(f.type_name)) {
            if (f.offset64) { panic("offset64 enum vectors are not supported by flatc") }
            let ei = fb_enum_index(s, f.type_name)
            if (ei < 0) { panic("unknown enum: {f.type_name}") }
            if (!s.enums[ei].is_union && s.enums[ei].underlying != (f.kind == 14 || f.kind == 17 ? f.element : f.kind)) { panic("enum backing type mismatch: {f.name}") }
            if (!s.enums[ei].is_union && f.kind != 14 && f.kind != 17 && !f.optional) {
                let desired = t.is_struct ? "0" : f.default_value
                var found = false
                for (v in s.enums[ei].values) { if (v.value == desired) { found = true } }
                if (!found) { panic("enum default is not a member: {t.name}.{f.name}") }
            }
        }
    }
    var size = t.is_struct ? 0 : 4
    var align = t.is_struct ? 1 : 4
    for (id in range(length(t.fields))) {
        for (f in t.fields) {
            if (f.id != id) { continue }
            let a = fb_inline_alignment(s, f)
            size = fb_round_up(size, a)
            f.offset = size
            size += fb_inline_size(s, f)
            align = max(align, a)
        }
    }
    if (t.force_align != 0) {
        if (!t.is_struct || t.force_align < align || t.force_align > 256 || (t.force_align & (t.force_align-1)) != 0) { panic("invalid force_align: {t.name}") }
        align = t.force_align
    }
    t.alignment = align
    t.byte_size = fb_round_up(size, align)
    if (!t.is_struct && t.byte_size > 65535) { panic("table inline size exceeds vtable limit") }
    if (t.is_struct) {
        for (f in t.fields) {
            var end = t.byte_size
            for (next in t.fields) { if (next.id == f.id+1) { end = next.offset } }
            f.padding = end-f.offset-fb_inline_size(s, f)
        }
    }
    s.tables[index] <- t
    states[index] = 2
}
def fb_normalize(var s : FBSchema) {
    var names : table<string; bool>
    for (e in s.enums) {
        let name = fb_qualified(e.name_space, e.name)
        if (!fb_identifier(e.name) || !fb_namespace(e.name_space) || key_exists(names, name)) { panic("invalid or duplicate enum: {name}") }
        names[name] = true
        if ((!e.is_union && (e.underlying < 3 || e.underlying > 10)) || empty(e.values)) { panic("invalid enum backing type or empty enum: {name}") }
        var members : table<string; bool>
        var tags:table<int;bool>
        for (v in e.values) {
            if (!fb_identifier(v.name) || key_exists(members, v.name)) { panic("invalid enum member: {v.name}") }
            members[v.name] = true
            if(e.is_union){
                let tag=int(v.value)
                if(tag<0 || tag>255 || key_exists(tags,tag)){panic("union tags must be unique bytes")}
                if((tag==0)!=(v.kind==0)){panic("union tag zero is reserved for NONE")}
                if(v.kind!=0 && v.kind!=13 && v.kind!=15){panic("invalid union payload type")}
                tags[tag]=true
            }
        }
        if(e.is_union && (!key_exists(tags,0) || e.values[0].kind!=0)){panic("union must begin with NONE")}
    }
    for (t in s.tables) {
        let name = fb_qualified(t.name_space, t.name)
        if (key_exists(names, name)) { panic("duplicate type: {name}") }
        names[name] = true
        let error = fb_validate(t)
        if (!empty(error)) { panic("{t.name}: {error}") }
    }
    var states : array<int>
    resize(states, length(s.tables))
    for (i in range(length(s.tables))) { fb_layout(s, i, states) }
}
def fb_buffer_alignment(s : FBSchema) : int {
    var align = 8
    for (t in s.tables) { align = max(align, t.alignment) }
    return align
}
def fb_prefix_width(s:FBSchema) : int {
    for(t in s.tables){for(f in t.fields){if(f.offset64){return 8}}}
    return 4
}

def fb_scalar(k : int) : bool => k >= 2 && k <= 12
def fb_width(k : int) : int {
    if (k >= 1 && k <= 4) { return 1 }
    if (k == 5 || k == 6) { return 2 }
    if (k == 9 || k == 10 || k == 12) { return 8 }
    if (k == 7 || k == 8 || k == 11 || k == 13 || k == 14 || k == 16) { return 4 }
    return 0
}
def fb_type_name(k : int) : string {
    let names = ["", "", "bool", "byte", "ubyte", "short", "ushort", "int", "uint", "long", "ulong", "float", "double", "string"]
    return k >= 2 && k <= 13 ? names[k] : ""
}
def fb_das_type(k : int) : string {
    let names = ["", "", "bool", "int8", "uint8", "int16", "uint16", "int", "uint", "int64", "uint64", "float", "double", "string"]
    return k >= 2 && k <= 13 ? names[k] : ""
}
def fb_identifier(s : string) : bool {
    if (empty(s)) { return false }
    var good = true
    var index = 0
    peek_data(s) $(bytes) {
        for (byte in bytes) {
            let c = uint(byte)
            if (!((c >= 65u && c <= 90u) || (c >= 97u && c <= 122u) || c == 95u || (index > 0 && c >= 48u && c <= 57u))) { good = false }
            index++
        }
    }
    return good
}
def fb_namespace(s : string) : bool {
    if (empty(s)) { return true }
    let parts <- split(s, ".")
    for (part in parts) {
        if (!fb_identifier(part)) { return false }
    }
    return true
}
def fb_validate(t : FBTable) : string {
    if (!fb_identifier(t.name) || !fb_namespace(t.name_space)) { return "invalid table name or namespace" }
    if (!empty(t.identifier) && length(t.identifier) != 4) { return "file identifier must contain exactly four ASCII bytes" }
    if (!empty(t.identifier) && !t.is_root) { return "file identifier requires root=true" }
    for (c in t.identifier) {
        if (c < 32 || c > 126 || c == 34 || c == 92) { return "unsupported file identifier character" }
    }
    if (length(t.fields) > 4094) { return "too many fields" }
    if (t.is_struct && (t.is_root || !empty(t.identifier) || empty(t.fields))) { return "fixed struct cannot be a root or empty" }
    var seen : table<int; bool>
    var names : table<string; bool>
    for (f in t.fields) {
        if (!fb_identifier(f.name)) { return "invalid field name: {f.name}" }
        if (key_exists(names, f.name)) { return "duplicate field name: {f.name}" }
        names[f.name] = true
        if (f.id < 0 || f.id >= length(t.fields)) { return "field ids must be contiguous from zero: {f.name}" }
        if (key_exists(seen, f.id)) { return "duplicate field id: {f.id}" }
        seen[f.id] = true
        if (!(f.kind == 1 || f.kind == 16 || fb_scalar(f.kind) || f.kind == 13 || f.kind == 15 || ((f.kind == 14 || f.kind == 17) && (f.element == 1 || f.element == 16 || fb_scalar(f.element) || f.element == 13 || f.element == 15)))) { return "unsupported field type: {f.name}" }
        if (f.kind == 10 && !t.is_struct && !empty(f.default_value) && uint64(f.default_value) > 9223372036854775807ul) { return "ulong default exceeds INT64_MAX; flatc loses it in BFBS" }
        if (t.is_struct && (!fb_scalar(f.kind) && f.kind != 15 && f.kind != 17 || f.required || f.deprecated)) { return "fixed structs support only scalars, enums and fixed structs: {f.name}" }
        if ((f.optional || f.optional_table) && (t.is_struct || (f.required && !f.boxed) || f.kind == 17)) { return "Option is only valid for non-required table fields: {f.name}" }
        if(f.optional && f.kind==16){return "union already has a none case; Option<union> is ambiguous"}
        if (f.kind == 17 && (!t.is_struct || f.fixed_length <= 0 || f.fixed_length > 65535 || f.element == 13)) { return "fixed arrays require a struct and scalar/struct elements: {f.name}" }
        if (f.offset64 && (f.kind != 13 && f.kind != 14)) { return "offset64 requires a string or vector" }
        if (f.offset64 && f.kind == 14 && f.element == 13) { return "offset64 string vectors are not supported by flatc" }
        if (f.vector64 && (f.kind != 14 || !f.offset64)) { return "vector64 requires a wide vector" }
        if (f.key && (t.is_struct || f.optional || (!fb_scalar(f.kind) && f.kind != 13))) { return "key must be a non-optional scalar or string: {f.name}" }
        if (f.required && (fb_scalar(f.kind) || f.deprecated)) { return "required is only valid on non-deprecated strings/vectors: {f.name}" }
    }
    return ""
}
def fb_emit_table(t : FBTable) : string {
    var out = ""
    if (!empty(t.name_space)) { out += "namespace {t.name_space};\n\n" }
    else { out += "namespace;\n\n" }
    out += fb_docs(t.documentation)
    out += "{t.is_struct ? "struct" : "table"} {t.name}"
    if(t.force_align!=0 || !empty(t.attributes)){
        out+=" ("
        if(t.force_align!=0){out+="force_align: {t.force_align}"}
        out+=fb_attributes(t.attributes,t.force_align!=0)+")"
    }
    out += " \{\n"
    for (id in range(length(t.fields))) {
        for (f in t.fields) {
            if (f.id != id || f.kind == 1 || (f.kind == 14 && f.element == 1)) { continue }
            let base = !empty(f.type_name) ? f.type_name : fb_type_name(f.kind == 14 || f.kind == 17 ? f.element : f.kind)
            let tn = f.kind == 14 ? "[{base}]" : (f.kind == 17 ? "[{base}:{f.fixed_length}]" : base)
            out += fb_docs(f.documentation,"  ")
            out += "  {f.name}:{tn}"
            if (!t.is_struct) {
                if (fb_scalar(f.kind)) { out += f.optional ? " = null" : " = {f.default_value}" }
                out += " (id: {f.id}"
                if (f.deprecated) { out += ", deprecated" }
                if (f.required) { out += ", required" }
                if (f.key) { out += ", key" }
                if (!empty(f.nested_buffer)) { out += ", nested_flatbuffer: \"{f.nested_buffer}\"" }
                if (f.offset64) { out += ", offset64" }
                if (f.vector64) { out += ", vector64" }
                out += fb_attributes(f.attributes,true)
                out += ")"
            }
            if(t.is_struct && !empty(f.attributes)){out+=" ("+fb_attributes(f.attributes,false)+")"}
            out += ";\n"
        }
    }
    out += "}\n"
    return out
}
def fb_emit_fixed(s : FBSchema; i : int; var state : array<int>; source:string="") : string {
    if(!empty(source) && s.tables[i].declaration_file!=source){return ""}
    if (state[i] == 2) { return "" }
    if (state[i] == 1) { panic("cyclic inline struct layout") }
    state[i] = 1
    var out = ""
    for (f in s.tables[i].fields) {
        if (f.kind == 15 || (f.kind == 17 && f.element == 15)) {
            let dep = fb_object_index(s, f.type_name)
            if (dep < 0 || !s.tables[dep].is_struct) { panic("invalid fixed struct dependency") }
            out += fb_emit_fixed(s, dep, state,source)
        }
    }
    out += fb_emit_table(s.tables[i]) + "\n"
    state[i] = 2
    return out
}
def fb_emit_schema(s : FBSchema; source:string="") : string {
    var out = "// Generated by dascript-flatbuffers.\n"
    var attrs:table<string;bool>
    for(t in s.tables){
        for(a in t.attributes){attrs[a.name]=true}
        for(f in t.fields){for(a in f.attributes){attrs[a.name]=true}}
    }
    for(e in s.enums){for(a in e.attributes){attrs[a.name]=true}}
    for(service in s.services){for(a in service.attributes){attrs[a.name]=true};for(call in service.calls){for(a in call.attributes){attrs[a.name]=true}}}
    for(name in keys(attrs)){if(fb_builtin_attribute(name)){continue};out+="attribute "+fb_quote(name)+";\n"}
    for (e in s.enums) {
        if(!empty(source) && e.declaration_file!=source){continue}
        out += empty(e.name_space) ? "namespace;\n" : "namespace {e.name_space};\n"
        out+=fb_docs(e.documentation)
        out += e.is_union ? "union {e.name}" : "enum {e.name}:{fb_type_name(e.underlying)}"
        if(!empty(e.attributes)){out+=" ("+fb_attributes(e.attributes,false)+")"}
        out+=" \{\n"
        for (v in e.values) {
            if (e.is_union) {
                if (v.kind != 0) { out += "  {v.name}:{v.kind == 13 ? "string" : v.type_name} = {v.value},\n" }
            } else { out += "  {v.name} = {v.value},\n" }
        }
        out += "}\n\n"
    }
    var names : table<string; bool>
    for (t in s.tables) {
        let err = fb_validate(t)
        if (!empty(err)) { panic(err) }
        let qualified = empty(t.name_space) ? t.name : "{t.name_space}.{t.name}"
        if (key_exists(names, qualified)) { panic("duplicate table: {qualified}") }
        names[qualified] = true
    }
    var states : array<int>
    resize(states, length(s.tables))
    for (i in range(length(s.tables))) {
        if (s.tables[i].is_struct) { out += fb_emit_fixed(s, i, states,source) }
    }
    for (t in s.tables) {
        if (!t.is_struct && (empty(source) || t.declaration_file==source)) { out += fb_emit_table(t) + "\n" }
    }
    for(service in s.services){
        if(!empty(source) && service.declaration_file!=source){continue}
        let dot=rfind(service.name,".")
        out+=dot<0 ? "namespace;\n" : "namespace "+slice(service.name,0,dot)+";\n"
        out+=fb_docs(service.documentation)
        out+="rpc_service "+(dot<0 ? service.name : slice(service.name,dot+1))
        if(!empty(service.attributes)){out+=" ("+fb_attributes(service.attributes,false)+")"}
        out+=" \{\n"
        for(call in service.calls){
            out+=fb_docs(call.documentation,"  ")
            out+="  {call.name}({call.request}):{call.response}"
            if(!empty(call.attributes)){out+=" ("+fb_attributes(call.attributes,false)+")"}
            out+=";\n"
        }
        out+="}\n"
    }
    if(!empty(s.file_extension)){out+="file_extension "+fb_quote(s.file_extension)+";\n"}
    var roots = 0
    for (t in s.tables) {
        if (!t.is_root || (!empty(source) && t.declaration_file!=source)) { continue }
        roots++
        let qn = empty(t.name_space) ? t.name : "{t.name_space}.{t.name}"
        out += "root_type {qn};\n"
        if (!empty(t.identifier)) { out += "file_identifier \"{t.identifier}\";\n" }
    }
    if (roots > 1) { panic("multiple root tables") }
    return out
}
