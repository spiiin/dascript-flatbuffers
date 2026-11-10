options gen2
module ast_adapter public
require strings
require daslib/strings_boost
require daslib/ast
require daslib/ast_boost
require ./ir.das public

def fb_ast_kind(t : Type) : int {
    if (t == Type.tBool) { return 2 }
    if (t == Type.tInt8) { return 3 }
    if (t == Type.tUInt8) { return 4 }
    if (t == Type.tInt16) { return 5 }
    if (t == Type.tUInt16) { return 6 }
    if (t == Type.tInt) { return 7 }
    if (t == Type.tUInt) { return 8 }
    if (t == Type.tInt64) { return 9 }
    if (t == Type.tUInt64) { return 10 }
    if (t == Type.tFloat) { return 11 }
    if (t == Type.tDouble) { return 12 }
    if (t == Type.tString) { return 13 }
    if (t == Type.tArray) { return 14 }
    if (t == Type.tStructure) { return 15 }
    return 0
}
def fb_ast_number(e : ExpressionPtr) : string {
    if (e == null) { return "0" }
    if (e is ExprConstInt8) { return "{int((e as ExprConstInt8).value)}" }
    if (e is ExprConstUInt8) { return "{uint((e as ExprConstUInt8).value):d}" }
    if (e is ExprConstInt16) { return "{int((e as ExprConstInt16).value)}" }
    if (e is ExprConstUInt16) { return "{uint((e as ExprConstUInt16).value):d}" }
    if (e is ExprConstBool) { return (e as ExprConstBool).value ? "true" : "false" }
    if (e is ExprConstInt) { return "{(e as ExprConstInt).value}" }
    if (e is ExprConstUInt) { return "{(e as ExprConstUInt).value:d}" }
    if (e is ExprConstInt64) { return "{(e as ExprConstInt64).value}" }
    if (e is ExprConstUInt64) { return "{(e as ExprConstUInt64).value:d}" }
    if (e is ExprConstFloat) { return "{(e as ExprConstFloat).value:.9g}" }
    if (e is ExprConstDouble) { return "{(e as ExprConstDouble).value:.17g}" }
    if (e is ExprConstEnumeration) {
        let ce = e as ExprConstEnumeration
        for (v in ce.enumType.list) {
            if (v.name == ce.value) { return fb_ast_number(v.value) }
        }
    }
    return ""
}
def fb_ast_meta(st : StructurePtr) : FBTable {
    var t : FBTable
    t.name = string(st.name)
    var found = 0
    for (a in st.annotations) {
        if (a.annotation.name != "fb_table" && a.annotation.name != "fb_struct") { continue }
        found++
        t.is_struct = a.annotation.name == "fb_struct"
        for (arg in a.arguments) {
            if (arg.name == "root") { t.is_root = arg.bValue }
            if (arg.name == "name") { t.name = string(arg.sValue) }
            if (arg.name == "namespace") { t.name_space = string(arg.sValue) }
            if (arg.name == "identifier") { t.identifier = string(arg.sValue) }
            if (arg.name == "align") { t.force_align = arg.iValue }
            if(find(string(arg.name),"attr_")==0){emplace(t.attributes,FBAttribute(name=slice(string(arg.name),5),value=string(arg.sValue)))}
        }
    }
    if (found != 1 || st.parent != null || st.flags.isClass) { panic("expected one fb_table/fb_struct annotation on a plain struct: {st.name}") }
    return <- t
}
def fb_ast_enum(enu : EnumerationPtr) : FBEnum {
    var e : FBEnum
    e.name = string(enu.name)
    e.underlying = fb_ast_kind(enu.baseType)
    var found = false
    var wire_names:array<string>
    for (a in enu.annotations) {
        if (a.annotation.name != "fb_enum") { continue }
        found = true
        for (arg in a.arguments) {
            if (arg.name == "name") { e.name = string(arg.sValue) }
            if (arg.name == "namespace") { e.name_space = string(arg.sValue) }
            if(arg.name=="names"){wire_names <- split(string(arg.sValue),",")}
            if(find(string(arg.name),"attr_")==0){emplace(e.attributes,FBAttribute(name=slice(string(arg.name),5),value=string(arg.sValue)))}
        }
    }
    if (!found) { panic("enum requires fb_enum annotation: {enu.name}") }
    for (v in enu.list) {
        let number = fb_ast_number(v.value)
        if (empty(number)) { panic("enum value must be a resolved integer constant: {enu.name}.{v.name}") }
        let name=empty(wire_names) ? string(v.name) : wire_names[length(e.values)]
        emplace(e.values, FBEnumValue(name=name, value=number))
    }
    return <- e
}
// Option<T> is a structural variant; aliases resolve to the same shape.
def fb_ast_is_option(td : TypeDeclPtr) : bool {
    return (td.baseType == Type.tVariant && length(td.argTypes) == 2 && length(td.argNames) == 2
        && td.argNames[0] == "none" && td.argNames[1] == "some"
        && td.argTypes[0].baseType == Type.tVoid)
}
def fb_ast_is_box(td : TypeDeclPtr) : bool {
    if (td.baseType != Type.tStructure || length(td.structType.fields) != 1) { return false }
    for (a in td.structType.fields[0].annotation) { if (a.name == "fb_reference") { return true } }
    return false
}
def fb_ast_payload(td : TypeDeclPtr) : TypeDeclPtr const {
    if (fb_ast_is_box(td)) { return td.structType.fields[0]._type.firstType }
    return fb_ast_is_option(td) ? td.argTypes[1] : td
}
def fb_ast_object_type(td : TypeDeclPtr) : StructurePtr const {
    let payload = fb_ast_payload(td)
    return payload.baseType == Type.tArray || payload.baseType == Type.tFixedArray ? payload.firstType.structType : payload.structType
}

def fb_ast_field_type(td : TypeDeclPtr; var f : FBField; var s : FBSchema) {
    if (td.flags.ref || td.flags.constant) { f.kind = 0; return }
    f.boxed = fb_ast_is_box(td)
    f.optional = fb_ast_is_option(td) || f.boxed
    let payload = fb_ast_payload(td)
    let vector = payload.baseType == Type.tArray
    let fixed = payload.baseType == Type.tFixedArray
    let elem = vector || fixed ? payload.firstType : payload
    if (elem.flags.ref || elem.flags.constant || fb_ast_is_option(elem)) { panic("invalid Option payload or vector element: {f.name}") }
    let k = elem.baseType == Type.tVariant ? 16 : (elem.isEnum ? fb_ast_kind(elem.enumType.baseType) : fb_ast_kind(elem.baseType))
    f.kind = fixed ? 17 : (vector ? 14 : k)
    f.element = vector || fixed ? k : 0
    f.fixed_length = fixed ? payload.fixedDim : 0
    if (k == 16) {
        if (length(elem.argTypes) < 2 || elem.argTypes[0].baseType != Type.tVoid || elem.argNames[0] != "none") { panic("union variant must begin with none:void") }
        if (empty(f.type_name)) { panic("union field requires @fb_union with its wire name") }
        var e : FBEnum
        let dot = rfind(f.type_name, ".")
        e.name = dot < 0 ? f.type_name : slice(f.type_name,dot+1)
        e.name_space = dot < 0 ? "" : slice(f.type_name,0,dot)
        e.is_union = true
        e.underlying = 1
        let tags <- split(f.union_values,",")
        let names <- split(f.union_names,",")
        if((!empty(f.union_values) && length(tags)!=length(elem.argTypes)) || (!empty(f.union_names) && length(names)!=length(elem.argTypes))){panic("union metadata must match the variant member count")}
        for (i in range(length(elem.argTypes))) {
            let original_type = elem.argTypes[i]
            let typ = fb_ast_payload(original_type)
            var v = FBEnumValue(name=i == 0 ? "NONE" : string(elem.argNames[i]), value="{i}")
            v.boxed=fb_ast_is_box(original_type)
            if(!empty(f.union_values)){v.value=tags[i]}
            if(!empty(f.union_names)){v.name=names[i]}
            v.kind = i == 0 ? 0 : fb_ast_kind(typ.baseType)
            if (v.kind == 15) { let meta <- fb_ast_meta(typ.structType); v.type_name = fb_qualified(meta.name_space,meta.name) }
            elif (i != 0 && v.kind != 13) { panic("union members must be tables, structs or strings") }
            emplace(e.values,v)
        }
        let existing = fb_enum_index(s,f.type_name)
        if (existing < 0) { emplace(s.enums,e) }
        else {
            if (!s.enums[existing].is_union || length(s.enums[existing].values) != length(e.values)) { panic("conflicting union declaration") }
            for (i in range(length(e.values))) {
                if (s.enums[existing].values[i].name != e.values[i].name || s.enums[existing].values[i].type_name != e.values[i].type_name || s.enums[existing].values[i].kind != e.values[i].kind) { panic("conflicting union member") }
            }
        }
    } elif (elem.isEnum) {
        var e <- fb_ast_enum(elem.enumType)
        f.type_name = fb_qualified(e.name_space, e.name)
        let existing = fb_enum_index(s, f.type_name)
        if (existing < 0) { emplace(s.enums, e) }
        else {
            if (s.enums[existing].underlying != e.underlying || length(s.enums[existing].values) != length(e.values)) { panic("conflicting enum declarations: {f.type_name}") }
            for (i in range(length(e.values))) {
                if (s.enums[existing].values[i].name != e.values[i].name || s.enums[existing].values[i].value != e.values[i].value) { panic("conflicting enum declarations: {f.type_name}") }
            }
        }
    } elif (k == 15) {
        let t <- fb_ast_meta(elem.structType)
        f.type_name = fb_qualified(t.name_space, t.name)
        f.optional_table = f.optional && !t.is_struct && !vector
        if (f.boxed && t.is_struct) { panic("FBRef requires a table payload") }
    }
}
def fb_ast_collect(st : StructurePtr; var s : FBSchema; var visited : table<string; string>; top : bool; depth : int) {
    if (depth > 64) { panic("schema dependency depth exceeds 64") }
    var t <- fb_ast_meta(st)
    let key = fb_qualified(t.name_space, t.name)
    let native = "{st._module.name}::{st.name}"
    if (key_exists(visited, key)) {
        if (visited[key] != native) { panic("duplicate wire type name: {key}") }
        return
    }
    visited[key] = native
    if (!top) { t.is_root = false; t.identifier = "" }
    var order = 0
    for (field in st.fields) {
        var f : FBField
        f.name = string(field.name)
        f.native_name = f.name
        f.id = t.is_struct ? order : -1
        for (a in field.annotation) { if (a.name == "fb_union" && a.basicType == Type.tString) { f.type_name = string(a.sValue) } }
        for(a in field.annotation){
            if(a.name=="fb_union_values"){f.union_values=string(a.sValue)}
            if(a.name=="fb_union_names"){f.union_names=string(a.sValue)}
        }
        fb_ast_field_type(field._type, f, s)
        for (a in field.annotation) {
            if (a.name == "fb_id" && a.basicType == Type.tInt) {
                f.id = a.iValue
                if (t.is_struct && f.id != order) { panic("fixed struct field order cannot be changed with fb_id") }
            } elif (a.name == "fb_deprecated" && a.basicType == Type.tBool) { f.deprecated = a.bValue }
            elif (a.name == "fb_required" && a.basicType == Type.tBool) { f.required = a.bValue }
            elif (a.name == "fb_default" && a.basicType == Type.tString) { f.default_value=string(a.sValue) }
            elif (a.name == "fb_name" && a.basicType == Type.tString) { f.name = string(a.sValue) }
            elif (a.name == "fb_key" && a.basicType == Type.tBool) { f.key = a.bValue }
            elif (a.name == "fb_nested" && a.basicType == Type.tString) { f.nested_buffer = string(a.sValue) }
            elif (a.name == "fb_offset64" && a.basicType == Type.tBool) { f.offset64 = a.bValue }
            elif (a.name == "fb_vector64" && a.basicType == Type.tBool) { f.vector64 = a.bValue }
            elif ((a.name == "fb_union" || a.name=="fb_union_values" || a.name=="fb_union_names") && a.basicType == Type.tString) { }
            elif(find(string(a.name),"fb_attr_")==0 && a.basicType==Type.tString){emplace(f.attributes,FBAttribute(name=slice(string(a.name),8),value=string(a.sValue)))}
            elif (find(string(a.name), "fb_") == 0) { panic("unknown or invalid field annotation: {a.name}") }
        }
        if (f.vector64) { f.offset64 = true }
        if (t.is_struct && field.init != null) { panic("fixed struct fields cannot have defaults: {f.name}") }
        if (f.optional) {
            if (field.init != null) { panic("optional field initializers are not supported: {f.name}") }
            f.default_value = "null"
        } elif (fb_scalar(f.kind)) {
            if (field.init != null && field.init is ExprConstUInt64 && (field.init as ExprConstUInt64).value > 9223372036854775807ul) {
                panic("ulong default exceeds INT64_MAX; flatc loses it in BFBS: {f.name}")
            }
            if(empty(f.default_value)){f.default_value = fb_ast_number(field.init)}
            if (field.init == null && f.kind == 2) { f.default_value = "false" }
            if (empty(f.default_value)) { panic("scalar default must be a constant literal: {f.name}") }

        } elif (field.init != null) {
            var default_object = false
            if (f.kind == 15 && !f.optional_table && field.init is ExprMakeStruct) {
                let mk = field.init as ExprMakeStruct
                default_object = (mk.constructor == null || mk.constructor.flags.generated) && mk._block == null
                for (entry in mk.structs) {
                    for (value in *entry) { default_object = false }
                }
            }
            if (!default_object) { panic("reference field initializers are not supported: {f.name}") }
        }
        if (f.kind == 15 || ((f.kind == 14 || f.kind == 17) && f.element == 15)) {
            let nested = fb_ast_object_type(field._type)
            fb_ast_collect(nested, s, visited, false, depth+1)
        }
        if(!empty(f.nested_buffer)){
            if(f.kind!=14 || f.element!=4){panic("nested_flatbuffer requires a byte vector")}
            var nested:StructurePtr
            for_each_structure(st._module) $(candidate){
                var tagged=false
                for(a in candidate.annotations){if(a.annotation.name=="fb_table"){tagged=true}}
                if(tagged){
                    let meta <- fb_ast_meta(candidate)
                    if(fb_qualified(meta.name_space,meta.name)==f.nested_buffer || meta.name==f.nested_buffer){nested=candidate}
                }
            }
            if(nested==null){panic("nested_flatbuffer target must be an annotated table in this module")}
            let meta <- fb_ast_meta(nested)
            f.nested_buffer=fb_qualified(meta.name_space,meta.name)
            fb_ast_collect(nested,s,visited,false,depth+1)
        }
        if (f.kind == 16 || (f.kind == 14 && f.element == 16)) {
            let payload = fb_ast_payload(field._type)
            let variant_type = f.kind == 14 ? payload.firstType : payload
            for (member in variant_type.argTypes) {
                if (member.baseType == Type.tStructure) { fb_ast_collect(fb_ast_object_type(member),s,visited,false,depth+1) }
            }
            emplace(t.fields, FBField(name=f.name+"_type", id=f.id-1, kind=f.kind == 14 ? 14 : 1,
                element=f.kind == 14 ? 1 : 0, type_name=f.type_name, default_value="0", deprecated=f.deprecated))
        }
        emplace(t.fields, f)
        order++
    }
    emplace(s.tables, t)
}
def fb_ast_schema(st : StructurePtr) : FBSchema {
    var s : FBSchema
    var visited : table<string; string>
    fb_ast_collect(st, s, visited, true, 0)
    fb_normalize(s)
    return <- s
}
