options gen2
module bfbs public
require strings
require ./ir.das public
require ./runtime.das

// Minimal reflection.fbs reader. Field numbers are the stable reflection schema IDs.
def fb_ref_uint(b : array<uint8>; obj, id, width : int; fallback : uint64) : uint64 {
    let p = fb_field(b, obj, id, width)
    return p == 0 ? fallback : fb_uint(b, p, width)
}
def fb_ref_object(b : array<uint8>; obj, id : int) : int {
    let p = fb_field(b, obj, id, 4)
    return p == 0 ? 0 : fb_offset(b, p)
}
def fb_ref_string(b : array<uint8>; obj, id : int) : string {
    let p = fb_ref_object(b, obj, id)
    return p == 0 ? "" : fb_string_at(b, p)
}
def fb_ref_vector(b : array<uint8>; obj, id : int) : array<int> {
    var items : array<int>
    let p = fb_ref_object(b, obj, id)
    if (p == 0) { return <- items }
    let n = fb_uint(b, p, 4)
    if (n > uint64((length(b)-p-4)/4)) { panic("BFBS: invalid vector length") }
    for (i in range(int(n))) { push(items, fb_offset(b, p+4+4*i)) }
    return <- items
}
def fb_import_attributes(b:array<uint8>; obj,id:int) : array<FBAttribute> {
    var result:array<FBAttribute>
    for(at in fb_ref_vector(b,obj,id)){emplace(result,FBAttribute(name=fb_ref_string(b,at,0),value=fb_ref_string(b,at,1)))}
    return <- result
}
def fb_import_docs(b:array<uint8>; obj,id:int) : array<string> {
    var result:array<string>
    for(at in fb_ref_vector(b,obj,id)){push(result,fb_string_at(b,at))}
    return <- result
}
def fb_import_bfbs(b : array<uint8>) : FBSchema {
    let root = fb_root(b, "BFBS")
    if ((fb_ref_uint(b, root, 6, 8, 0ul) & ~7ul) != 0ul) { panic("BFBS: unsupported advanced_features") }
    let enums <- fb_ref_vector(b, root, 1)
    let services <- fb_ref_vector(b, root, 5)

    let root_table = fb_ref_object(b, root, 4)
    let objects <- fb_ref_vector(b, root, 0)
    if (empty(objects)) { panic("BFBS: schema has no objects") }
    var schema : FBSchema
    schema.file_extension=fb_ref_string(b,root,3)
    for(at in fb_ref_vector(b,root,7)){
        var source=FBSource(filename=fb_ref_string(b,at,0))
        source.includes <- fb_import_docs(b,at,1)
        emplace(schema.sources,source)
    }
    for(at in services){
        var service=FBService(name=fb_ref_string(b,at,0),declaration_file=fb_ref_string(b,at,4))
        service.attributes <- fb_import_attributes(b,at,2)
        service.documentation <- fb_import_docs(b,at,3)
        for(c in fb_ref_vector(b,at,1)){
            var call=FBRpcCall(name=fb_ref_string(b,c,0),request=fb_ref_string(b,fb_ref_object(b,c,1),0),response=fb_ref_string(b,fb_ref_object(b,c,2),0))
            call.attributes <- fb_import_attributes(b,c,3)
            call.documentation <- fb_import_docs(b,c,4)
            emplace(service.calls,call)
        }
        emplace(schema.services,service)
    }
    for (en in enums) {
        var e : FBEnum
        e.is_union = fb_ref_uint(b,en,2,1,0ul) != 0ul
        let qualified = fb_ref_string(b, en, 0)
        let dot = rfind(qualified, ".")
        e.name = dot < 0 ? qualified : slice(qualified, dot+1)
        e.name_space = dot < 0 ? "" : slice(qualified, 0, dot)
        let backing = fb_ref_object(b, en, 3)
        if (backing == 0) { panic("BFBS: enum missing underlying type") }
        e.underlying = int(fb_ref_uint(b, backing, 0, 1, 0ul))
        for(a in fb_import_attributes(b,en,4)){if(a.name!="bit_flags"){push_clone(e.attributes,a)}}
        e.documentation <- fb_import_docs(b,en,5)
        e.declaration_file=fb_ref_string(b,en,6)
        let values <- fb_ref_vector(b, en, 1)
        for (ev in values) {
            let bits = fb_ref_uint(b, ev, 1, 8, 0ul)
            let number = e.underlying == 4 || e.underlying == 6 || e.underlying == 8 || e.underlying == 10 ? "{bits:d}" : "{int64(bits)}"
            var v = FBEnumValue(name=fb_ref_string(b, ev, 0), value=number)
            if (e.is_union) {
                let typ = fb_ref_object(b,ev,3)
                if (typ != 0) {
                    v.kind = int(fb_ref_uint(b,typ,0,1,0ul))
                    if (v.kind == 15) {
                        let index = int(fb_ref_uint(b,typ,2,4,0xfffffffful))
                        if (index < 0 || index >= length(objects)) { panic("BFBS: invalid union object index") }
                        v.type_name = fb_ref_string(b,objects[index],0)
                    }
                }
            }
            emplace(e.values,v)
        }
        emplace(schema.enums, e)
    }
    var root_found = root_table == 0
    for (obj in objects) {
        var t : FBTable
        let qualified = fb_ref_string(b, obj, 0)
        let dot = rfind(qualified, ".")
        t.name = dot < 0 ? qualified : slice(qualified, dot+1)
        t.name_space = dot < 0 ? "" : slice(qualified, 0, dot)
        t.is_root = obj == root_table
        if (t.is_root) {
            root_found = true
            t.identifier = fb_ref_string(b, root, 2)
        }
        t.is_struct = fb_ref_uint(b, obj, 2, 1, 0ul) != 0ul
        t.alignment = int(fb_ref_uint(b, obj, 3, 4, 0ul))
        t.byte_size = int(fb_ref_uint(b, obj, 4, 4, 0ul))
        for(a in fb_import_attributes(b,obj,5)){if(a.name!="force_align"){push_clone(t.attributes,a)}}
        t.documentation <- fb_import_docs(b,obj,6)
        t.declaration_file=fb_ref_string(b,obj,7)
        let fields <- fb_ref_vector(b, obj, 1)
        for (field in fields) {
            var f : FBField
            f.name = fb_ref_string(b, field, 0)
            f.id = int(fb_ref_uint(b, field, 2, 2, 0ul))
            f.offset = int(fb_ref_uint(b, field, 3, 2, 0ul))
            f.padding = int(fb_ref_uint(b, field, 12, 2, 0ul))
            if (!t.is_struct && f.offset != 4+2*f.id) { panic("BFBS: inconsistent vtable field offset") }
            let typ = fb_ref_object(b, field, 1)
            if (typ == 0) { panic("BFBS: missing field type") }
            f.kind = int(fb_ref_uint(b, typ, 0, 1, 0ul))
            f.vector64 = f.kind == 18
            if (f.vector64) { f.kind = 14 }
            f.offset64 = fb_ref_uint(b,field,13,1,0ul) != 0ul
            f.element = int(fb_ref_uint(b, typ, 1, 1, 0ul))
            let index = int(fb_ref_uint(b, typ, 2, 4, 0xfffffffful))
            if (f.kind == 15 || ((f.kind == 14 || f.kind == 17) && f.element == 15)) {
                if (index < 0 || index >= length(objects)) { panic("BFBS: invalid object index") }
                f.type_name = fb_ref_string(b, objects[index], 0)
            } elif (index >= 0) {
                if (index >= length(enums)) { panic("BFBS: invalid enum index") }
                f.type_name = fb_ref_string(b, enums[index], 0)
            }
            f.fixed_length = int(fb_ref_uint(b, typ, 3, 2, 0ul))
            let integer = fb_ref_uint(b, field, 4, 8, 0ul)
            if (f.kind == 10) { f.default_value = "{integer:d}" }
            elif (f.kind == 2) { f.default_value = integer == 0ul ? "false" : "true" }
            elif (f.kind == 11 || f.kind == 12) {
                let real_bits = fb_ref_uint(b, field, 5, 8, 0ul)
                let real = unsafe(reinterpret<double>(real_bits))
                f.default_value = "{real:.17g}"
            } else { f.default_value = "{int64(integer)}" }
            f.deprecated = fb_ref_uint(b, field, 6, 1, 0ul) != 0ul
            f.required = fb_ref_uint(b, field, 7, 1, 0ul) != 0ul
            if (!t.is_struct && !f.required && f.kind != 16) {
                f.optional = fb_ref_uint(b, field, 11, 1, 0ul) != 0ul
            }
            if (!t.is_struct && f.kind == 15 && !f.required) {
                f.optional_table = fb_ref_uint(b, objects[index], 2, 1, 0ul) == 0ul
            }

            f.key = fb_ref_uint(b, field, 8, 1, 0ul) != 0ul
            f.attributes <- fb_import_attributes(b,field,9)
            f.documentation <- fb_import_docs(b,field,10)
            for(a in f.attributes){if(a.name=="nested_flatbuffer"){f.nested_buffer=a.value}}
            var custom:array<FBAttribute>
            for(a in f.attributes){if(a.name!="nested_flatbuffer" && a.name!="offset64" && a.name!="vector64" && a.name!="id" && a.name!="required" && a.name!="deprecated" && a.name!="key"){push_clone(custom,a)}}
            f.attributes <- custom
            emplace(t.fields, f)
        }
        let err = fb_validate(t)
        if (!empty(err)) { panic("BFBS {qualified}: {err}") }
        emplace(schema.tables, t)
    }
    if (!root_found) { panic("BFBS: root table is not in objects") }
    var reflected := schema
    fb_normalize(schema)
    // Reflection exposes the effective alignment, not always the force_align
    // attribute. Infer an explicit alignment only when natural layout differs.
    for (i in range(length(schema.tables))) {
        if (!schema.tables[i].is_struct) { continue }
        let expected = reflected.tables[i].alignment
        if (expected > schema.tables[i].alignment) { schema.tables[i].force_align = expected }
    }
    fb_normalize(schema)
    for (i in range(length(schema.tables))) {
        if (!schema.tables[i].is_struct) { continue }
        if (schema.tables[i].alignment != reflected.tables[i].alignment || schema.tables[i].byte_size != reflected.tables[i].byte_size) {
            panic("BFBS: inconsistent struct size/alignment")
        }
        for (j in range(length(schema.tables[i].fields))) {
            if (schema.tables[i].fields[j].offset != reflected.tables[i].fields[j].offset || schema.tables[i].fields[j].padding != reflected.tables[i].fields[j].padding) {
                panic("BFBS: inconsistent struct field offset/padding")
            }
        }
    }
    return <- schema
}

def fb_das_name(t : FBTable) : string {
    return fb_native_name(fb_qualified(t.name_space,t.name))
}
def fb_das_keyword(s : string) : bool {
    // Native names are escaped reversibly; schema names remain unchanged.
    let words = ["abstract", "addr", "aka", "array", "as", "assume", "auto", "bitfield", "block", "bool", "break", "byte16", "byte2", "byte3", "byte4", "byte8", "capture", "cast", "class", "const", "continue", "def", "default", "delete", "deref", "double", "elif", "else", "enum", "expect", "explicit", "false", "finally", "fixed_array", "float", "float16", "float2", "float3", "float4", "for", "function", "generator", "goto", "half2", "half3", "half4", "half8", "if", "implicit", "in", "include", "inscope", "int", "int16", "int2", "int3", "int4", "int64", "int8", "is", "iterator", "label", "lambda", "let", "module", "new", "null", "operator", "options", "override", "pass", "private", "public", "range", "range64", "recover", "reinterpret", "require", "return", "sealed", "shared", "short2", "short3", "short4", "short8", "smart_ptr", "static", "static_elif", "static_if", "string", "struct", "table", "template", "true", "try", "tuple", "type", "typedecl", "typedef", "typeinfo", "ubyte16", "ubyte2", "ubyte3", "ubyte4", "ubyte8", "uint", "uint16", "uint2", "uint3", "uint4", "uint64", "uint8", "uninitialized", "unsafe", "upcast", "urange", "urange64", "ushort2", "ushort3", "ushort4", "ushort8", "var", "variant", "void", "where", "while", "with", "yield"]
    for (w in words) { if (w == s) { return true } }
    return false
}
def fb_das_default(f : FBField) : string {
    let v = f.default_value
    // Decimal negative minima overflow in the daScript lexer before unary minus.
    if (f.kind == 7 && v == "-2147483648") { return "int(0x80000000u)" }
    if (f.kind == 9 && v == "-9223372036854775808") { return "int64(0x8000000000000000ul)" }
    if (f.kind == 2) { return v }
    if (f.kind == 9) { return "{v}l" }
    if (f.kind == 10) { return "{v}ul" }
    if (f.kind == 8) { return "{v}u" }
    if (f.kind == 11 || f.kind == 12) {
        if (v == "nan" || v == "inf" || v == "-inf") { panic("non-finite defaults are not yet supported") }
        let number = find(v, ".") < 0 && find(v, "e") < 0 && find(v, "E") < 0 ? v + ".0" : v
        return f.kind == 12 ? number + "lf" : number
    }
    return v
}
def fb_native_name(name : string) : string {
    if(find(name,"_")<0 && !fb_das_keyword(name)){return replace(name,".","_")}
    var result="_fb_"
    peek_data(name) $(bytes){for(c in bytes){result+="{uint(c):02x}"}}
    return result
}
def fb_box_visit(var s : FBSchema; index : int; var states : array<int>) {
    if (states[index] != 0) { return }
    states[index] = 1
    var t := s.tables[index]
    for (f in t.fields) {
        if(f.kind==16 || (f.kind==14 && f.element==16)){
            let ei=fb_enum_index(s,f.type_name)
            for(vi in range(length(s.enums[ei].values))){
                let member=s.enums[ei].values[vi]
                if(member.kind!=15){continue}
                let dep=fb_object_index(s,member.type_name)
                if(states[dep]==1 && !s.tables[dep].is_struct){s.enums[ei].values[vi].boxed=true}
                else{fb_box_visit(s,dep,states)}
            }
        }
        if (f.kind == 15 || (f.kind == 14 && f.element == 15)) {
            let dep = fb_object_index(s, f.type_name)
            if (states[dep] == 1 && f.kind == 15 && !s.tables[dep].is_struct) {
                f.boxed = true
                f.optional = true
            } else { fb_box_visit(s, dep, states) }
        }
    }
    s.tables[index] <- t
    states[index] = 2
}
def fb_box_cycles(var s : FBSchema) {
    var states : array<int>
    resize(states, length(s.tables))
    for (i in range(length(s.tables))) { fb_box_visit(s, i, states) }
}

def fb_emit_das_object(s : FBSchema; index : int; var emitted : array<int>) : string {
    if (emitted[index] == 2) { return "" }
    if (emitted[index] == 1) { panic("BFBS: cyclic by-value object declarations are not supported") }
    emitted[index] = 1
    var t := s.tables[index]
    var out = ""
    for (f in t.fields) {
        if (f.kind == 15 || ((f.kind == 14 || f.kind == 17) && f.element == 15)) {
            let dep = fb_object_index(s, f.type_name)
            if (f.boxed || (emitted[dep] == 1 && f.kind == 14)) { continue }
            out += fb_emit_das_object(s, dep, emitted)
        }
    }
    for (f in t.fields) {
        if (f.kind == 16 || (f.kind == 14 && f.element == 16)) {
            assume en = s.enums[fb_enum_index(s,f.type_name)]
            for (v in en.values) { if (v.kind == 15 && !v.boxed) { out += fb_emit_das_object(s,fb_object_index(s,v.type_name),emitted) } }
        }
    }
    let native = fb_das_name(t)
    let annotation = t.is_struct ? "fb_struct" : "fb_table"
    out += "[{annotation}(name=\"{t.name}\", namespace=\"{t.name_space}\""
    if (!t.is_struct) {
        out += ", root={t.is_root}"
        if (!empty(t.identifier)) { out += ", identifier=\"{t.identifier}\"" }
    } elif (t.force_align != 0) { out += ", align={t.force_align}" }
    for(a in t.attributes){out+=", attr_"+a.name+"="+fb_quote(a.value)}
    out += ")]\nstruct {native} \{\n"
    for (id in range(length(t.fields))) {
        for (f in t.fields) {
            if (f.id != id || f.kind == 1 || (f.kind == 14 && f.element == 1)) { continue }
            let native_field=fb_native_name(f.name)
            if(native_field!=f.name){out+="    @fb_name="+fb_quote(f.name)+"\n"}
            if (!t.is_struct) { out += "    @fb_id = {f.id}\n" }
            if (f.deprecated) { out += "    @fb_deprecated\n" }
            if (f.required) { out += "    @fb_required\n" }
            if (f.key) { out += "    @fb_key\n" }
            if(!empty(f.nested_buffer)){out+="    @fb_nested="+fb_quote(f.nested_buffer)+"\n"}
            for(a in f.attributes){out+="    @fb_attr_"+a.name+"="+fb_quote(a.value)+"\n"}
            if (f.vector64) { out += "    @fb_vector64\n" }
            elif (f.offset64) { out += "    @fb_offset64\n" }
            var base = !empty(f.type_name) ? fb_native_name(f.type_name) : fb_das_type(f.kind == 14 || f.kind == 17 ? f.element : f.kind)
            if (f.kind == 16 || (f.kind == 14 && f.element == 16)) {
                out += "    @fb_union=\"{f.type_name}\"\n"
                assume en = s.enums[fb_enum_index(s,f.type_name)]
                var tags=""
                var names=""
                for(v in en.values){if(!empty(tags)){tags+=",";names+=","};tags+=v.value;names+=v.name}
                out+="    @fb_union_values="+fb_quote(tags)+"\n    @fb_union_names="+fb_quote(names)+"\n"
                base = "variant<none"
                for (v in en.values) {
                    if (v.kind == 0) { continue }
                    let native_type=v.kind==13 ? "string" : fb_native_name(v.type_name)
                    let member_type=v.boxed ? "FBRef<{native_type}>" : native_type
                    base += "; {fb_native_name(v.name)}: {member_type}"
                }
                base += ">"
            }
            let raw = f.kind == 14 ? "array<{base}>" : (f.kind == 17 ? "{base}[{f.fixed_length}]" : base)
            let typ = f.boxed ? "FBRef<{raw}>" : (f.optional ? "Option<{raw}>" : raw)
            if(f.default_value=="nan" || f.default_value=="inf" || f.default_value=="-inf"){out+="    @fb_default="+fb_quote(f.default_value)+"\n"}
            out += "    {native_field} : {typ}"
            if (!t.is_struct && !f.optional && fb_scalar(f.kind) && f.default_value!="nan" && f.default_value!="inf" && f.default_value!="-inf") {
                if (!empty(f.type_name)) {
                    let ei = fb_enum_index(s, f.type_name)
                    var member = ""
                    for (v in s.enums[ei].values) { if (v.value == f.default_value) { member = v.name } }
                    if (empty(member)) { panic("enum default is not a member: {f.name}") }
                    out += " = {base}.{fb_native_name(member)}"
                } else { out += " = {fb_das_default(f)}" }
            }
            if (!t.is_struct && f.kind == 15 && !f.optional) { out += " = {base}()" }
            out += "\n"
        }
    }
    out += "}\n\n"
    emitted[index] = 2
    return out
}
def fb_emit_das(input : FBSchema; module_name, annotation_import : string) : string {
    var s := input
    fb_box_cycles(s)
    if (!fb_identifier(module_name) || fb_das_keyword(module_name)) { panic("invalid output module name") }
    if (find(annotation_import, "\n") >= 0 || find(annotation_import, "\r") >= 0 || find(annotation_import, " ") >= 0) { panic("invalid annotation import path") }
    var out = "// Generated from BFBS. Serialization is supplied by the shared macros.\noptions gen2\nmodule {module_name} public\nrequire {annotation_import} public\n\n"
    var names : table<string; bool>
    for (e in s.enums) {
        if (e.is_union) { continue }
        let native = fb_native_name(fb_qualified(e.name_space, e.name))
        if (key_exists(names, native) || fb_das_keyword(native)) { panic("generated daScript type name collision: {native}") }
        names[native] = true
        var wire_names=""
        for(v in e.values){if(!empty(wire_names)){wire_names+=","};wire_names+=v.name}
        out += "[fb_enum(name=\"{e.name}\", namespace=\"{e.name_space}\", names="+fb_quote(wire_names)
        for(a in e.attributes){out+=", attr_"+a.name+"="+fb_quote(a.value)}
        out+=")]\nenum {native} : {fb_das_type(e.underlying)} \{\n"
        for (v in e.values) {

            let field = FBField(kind=e.underlying, default_value=v.value)
            out += "    {fb_native_name(v.name)} = {fb_das_default(field)}\n"
        }
        out += "}\n\n"
    }
    for (t in s.tables) {
        let err = fb_validate(t)
        if (!empty(err)) { panic(err) }
        let native = fb_das_name(t)
        if (key_exists(names, native) || fb_das_keyword(native)) { panic("generated daScript type name collision: {native}") }
        names[native] = true
    }
    var emitted : array<int>
    resize(emitted, length(s.tables))
    for (i in range(length(s.tables))) { out += fb_emit_das_object(s, i, emitted) }
    for(service in s.services){for(call in service.calls){
        let request=fb_native_name(call.request)
        let response=fb_native_name(call.response)
        let method=service.name+"/"+call.name
        out+="def fb_rpc_"+fb_native_name(service.name)+"_"+fb_native_name(call.name)+"(request:"+request+"; transport:block<(method:string; payload:array<uint8>):array<uint8>>) : "+response+" \{\n"
        out+="    let request_bytes <- fb_pack_"+request+"(request)\n"
        out+="    let response_bytes <- invoke(transport,"+fb_quote(method)+",request_bytes)\n"
        out+="    if(!fb_verify_"+response+"(response_bytes)) \{ panic(\"invalid RPC response\") }\n"
        out+="    return <- fb_unpack_"+response+"(response_bytes)\n}\n"
    }}
    return out
}
