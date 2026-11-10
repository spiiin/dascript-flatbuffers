options gen2
module annotations public
require strings
require daslib/ast
require daslib/ast_boost
require daslib/templates_boost
require daslib/option public
require ./references.das public
require ./ast_adapter.das
require ./union_codegen.das
require ./ir.das public
require ./runtime.das public
require ./verifier.das public

def fb_macro_apply(var st : StructurePtr; args : AnnotationArgumentList; var errors : das_string; fixed : bool) : bool {
    for (a in args) {
        let text = find(string(a.name),"attr_")==0 || a.name == "namespace" || a.name == "name" || (!fixed && a.name == "identifier")
        let root = !fixed && a.name == "root"
        let align = fixed && a.name == "align"
        if (!(text || root || align)) { errors := "unknown fb annotation argument: {a.name}"; return false }
        if ((text && a.basicType != Type.tString) || (root && a.basicType != Type.tBool) || (align && a.basicType != Type.tInt)) {
            errors := "invalid fb annotation argument type: {a.name}"
            return false
        }
    }
    // daScript requires explicit construction of nested values with defaults.
    // Supply the default constructor, preserving the user's field declaration.
    if (!fixed) {
        for (field in st.fields) {
            for(a in field.annotation){
                if(a.name!="fb_default"){continue}
                if(field.init!=null){errors:="fb_default requires no native initializer";return false}
                let value=string(a.sValue)
                if(value!="nan" && value!="inf" && value!="-inf"){errors:="fb_default supports nan, inf or -inf";return false}
                if(field._type.baseType==Type.tFloat){
                    let bits=value=="nan" ? 0x7fc00000u : (value=="inf" ? 0x7f800000u : 0xff800000u)
                    field.init=qmacro(unsafe(reinterpret<float>($v(bits))))
                } elif(field._type.baseType==Type.tDouble){
                    let bits=value=="nan" ? 0x7ff8000000000000ul : (value=="inf" ? 0x7ff0000000000000ul : 0xfff0000000000000ul)
                    field.init=qmacro(unsafe(reinterpret<double>($v(bits))))
                } else { errors:="non-finite defaults require float or double";return false }
            }
            var union_field = false
            for (a in field.annotation) { if (a.name == "fb_union") { union_field = true } }
            if (union_field) { field.annotation |> add_annotation_argument("safe_when_uninitialized", true) }
            if (field.init == null && field._type.baseType == Type.tStructure && !fb_ast_is_box(field._type)) {
                field.init = qmacro(default<$t(field._type)>)
            }
        }
    }
    var pack = qmacro_function("fb_pack_{st.name}") $(obj : $t(st)) : array<uint8> {
        var result : array<uint8>
        return <- result
    }
    var build = qmacro_function("fb_build_{st.name}") $(obj:$t(st); var builder:FBBuilder; depth:int) : int { return 0 }
    var pack_depth = qmacro_function("fb_pack_depth_{st.name}") $(obj : $t(st); depth : int) : array<uint8> {
        var result : array<uint8>
        return <- result
    }
    var unpack = qmacro_function("fb_unpack_{st.name}") $(data : array<uint8>) : $t(st) {
        var result = default<$t(st)>
        return <- result
    }
    var unpack_at = qmacro_function("fb_unpack_at_{st.name}") $(data : array<uint8>; root, depth : int) : $t(st) {
        var result = default<$t(st)>
        return <- result
    }
    var schema = qmacro_function("fb_schema_{st.name}") $() : string { return "" }
    var descriptor = qmacro_function("fb_descriptor_{st.name}") $() : FBTable { var t : FBTable; return <- t }
    var schema_ir = qmacro_function("fb_schema_ir_{st.name}") $() : FBSchema { var s : FBSchema; return <- s }
    var view = qmacro_function("fb_view_{st.name}") $(data:array<uint8>) : FBView { return FBView() }
    var sort_stub = qmacro_function("fb_sort_{st.name}") $(var items:array<$t(st)>) { panic("table has no key") }
    var verify = qmacro_function("fb_verify_{st.name}") $(data:array<uint8>) : bool { return false }
    var pack_size = qmacro_function("fb_pack_size_prefixed_{st.name}") $(obj:$t(st)) : array<uint8> { var bytes:array<uint8>;return <- bytes }
    var read_size = qmacro_function("fb_unpack_size_prefixed_{st.name}") $(data:array<uint8>) : $t(st) { var obj=default<$t(st)>;return <- obj }
    for (fn in [pack, build, pack_depth, unpack, unpack_at, schema, descriptor, schema_ir, view, verify, pack_size, read_size,sort_stub]) {
        if (st._module |> find_unique_function(string(fn.name)) != null) {
            errors := "generated function already exists: {fn.name}"
            return false
        }
        fn.flags.generated = true
        fn.body |> force_at(st.at)
        add_function(st._module, fn)
    }
    return true
}
def fb_helper(st : StructurePtr; prefix : string) : string {
    return empty(st._module.name) ? "{prefix}_{st.name}" : "{st._module.name}::{prefix}_{st.name}"
}
def fb_replace_body(st : StructurePtr; name : string; var source : FunctionPtr) {
    var fn = st._module |> find_unique_function(name)
    fn.body = source.body
    fn.body |> force_at(st.at)
}
def fb_macro_patch(var st : StructurePtr; var args : AnnotationArgumentList; var astChanged : bool&) : bool {
    if (find_arg(args, "__fb_done") is tBool) { return true }
    var schema <- fb_ast_schema(st)
    let meta <- fb_ast_meta(st)
    var t := schema.tables[fb_object_index(schema, fb_qualified(meta.name_space, meta.name))]
    let schema_text = fb_emit_schema(schema)
    var schema_fn = qmacro_function("unused") $() : string { return $v(schema_text) }
    var desc_fn = qmacro_function("unused") $() : FBTable { return <- $v(t) }
    var ir_fn = qmacro_function("unused") $() : FBSchema { return <- $v(schema) }
    var writes : array<ExpressionPtr>
    var reads : array<ExpressionPtr>
    let buffer_alignment = fb_buffer_alignment(schema)
    let prefix_width=fb_prefix_width(schema)
    for (fi in range(length(t.fields))) {
        assume f = t.fields[fi]
        if (f.deprecated || f.kind == 1 || (f.kind == 14 && f.element == 1)) { continue }
        var native_index = -1
        for (i in range(length(st.fields))) { if (st.fields[i].name == f.native_name) { native_index = i } }
        assume field = st.fields[native_index]
        var field_writes : array<ExpressionPtr>
        var field_reads : array<ExpressionPtr>
        let native = string(field.name)
        let source = f.boxed ? qmacro(obj.$f(native).value[0]) : (f.optional ? qmacro(obj.$f(native) as some) : qmacro(obj.$f(native)))
        let destination = f.optional ? qmacro(optional_value) : qmacro(result.$f(native))
        if (f.kind == 16 || (f.kind == 14 && f.element == 16)) {
            fb_union_codegen(schema,f,fb_ast_payload(field._type),source,destination,field_writes,field_reads)
        } elif (f.kind == 15 || ((f.kind == 14 || f.kind == 17) && f.element == 15)) {
            let child_type = fb_ast_object_type(field._type)
            var child := schema.tables[fb_object_index(schema, f.type_name)]
            let pack_child = fb_helper(child_type, "fb_pack_depth")
            let build_child = fb_helper(child_type,"fb_build")
            let read_child = fb_helper(child_type, "fb_unpack_at")
            let inline_size = child.is_struct ? child.byte_size : 0
            if (f.kind == 17) {
                field_writes |> push <| qmacro_block() {
                    for (i in range($v(f.fixed_length))) {
                        let bytes <- $c(pack_child)($e(source)[i], depth+1)
                        fb_copy_inline(builder.bytes, $v(f.offset)+i*$v(child.byte_size), bytes)
                    }
                }
                field_reads |> push <| qmacro_block() {
                    for (i in range($v(f.fixed_length))) {
                        $e(destination)[i] <- $c(read_child)(data, root+$v(f.offset)+i*$v(child.byte_size), depth+1)
                    }
                }
            } elif (f.kind==14 && !child.is_struct) {
                field_writes |> push <| qmacro_block() {
                    let vector=fb_reserve_objects(builder,$v(f.id),length($e(source)))
                    for(i in range(length($e(source)))){
                        let child=$c(build_child)($e(source)[i],builder,depth+1)
                        fb_set_object(builder,vector+i*4,child)
                    }
                }
                field_reads |> push <| qmacro_block() {
                    let positions <- fb_object_positions(data,root,$v(f.id),4,$v(f.required),false)
                    for(at in positions){var item <- $c(read_child)(data,at,depth+1);emplace($e(destination),item)}
                }
            } elif (f.kind == 14) {
                let stride = child.is_struct ? child.byte_size : 4
                field_writes |> push <| qmacro_block() {
                    var encoded : array<array<uint8>>
                    for (item in $e(source)) {
                        var bytes <- $c(pack_child)(item, depth+1)
                        emplace(encoded, bytes)
                    }
                    if ($v(f.offset64)) { fb_write_wide_structs(builder,$v(f.id),encoded,$v(stride),$v(buffer_alignment),$v(f.vector64)) }
                    else { fb_write_objects(builder, $v(f.id), encoded, $v(stride), $v(buffer_alignment), $v(child.is_struct)) }
                }
                field_reads |> push <| qmacro_block() {
                    var positions : array<int>
                    if ($v(f.offset64)) { positions <- fb_wide_struct_positions(data,root,$v(f.id),$v(stride),$v(f.required),$v(f.vector64)) }
                    else { positions <- fb_object_positions(data, root, $v(f.id), $v(stride), $v(f.required), $v(child.is_struct)) }
                    for (at in positions) {
                        var item <- $c(read_child)(data, at, depth+1)
                        emplace($e(destination), item)
                    }
                }
            } elif (t.is_struct) {
                field_writes |> push <| qmacro_block() {
                    let bytes <- $c(pack_child)($e(source), depth+1)
                    fb_copy_inline(builder.bytes, $v(f.offset), bytes)
                }
                field_reads |> push <| qmacro_block() {
                    $e(destination) <- $c(read_child)(data, root+$v(f.offset), depth+1)
                }
            } elif (!child.is_struct) {
                field_writes |> push <| qmacro_block() {
                    let child=$c(build_child)($e(source),builder,depth+1)
                    fb_reference(builder,$v(f.id),child)
                }
                field_reads |> push <| qmacro_block() {
                    let at=fb_nested_position(data,root,$v(f.id),$v(f.required),0)
                    if(at!=0){$e(destination) <- $c(read_child)(data,at,depth+1)}
                }
            } else {
                field_writes |> push <| qmacro_block() {
                    let bytes <- $c(pack_child)($e(source), depth+1)
                    fb_write_object(builder, $v(f.id), bytes, $v(child.is_struct), $v(buffer_alignment))
                }
                field_reads |> push <| qmacro_block() {
                    let at = fb_nested_position(data, root, $v(f.id), $v(f.required), $v(inline_size))
                    if (at != 0) { $e(destination) <- $c(read_child)(data, at, depth+1) }
                }
            }
        } elif (f.kind == 17) {
            let width = fb_width(f.element)
            field_writes |> push <| qmacro_block() {
                for (i in range($v(f.fixed_length))) { fb_write_inline(builder.bytes, $v(f.offset)+i*$v(width), $e(source)[i]) }
            }
            field_reads |> push <| qmacro_block() {
                for (i in range($v(f.fixed_length))) { fb_read_inline(data, root+$v(f.offset)+i*$v(width), $e(destination)[i]) }
            }
        } elif (t.is_struct) {
            push(field_writes, qmacro(fb_write_inline(builder.bytes, $v(f.offset), $e(source))))
            push(field_reads, qmacro(fb_read_inline(data, root+$v(f.offset), $e(destination))))
        } elif (!empty(f.nested_buffer)) {
            push(field_writes,qmacro(fb_write_nested(builder,$v(f.id),$e(source),$v(buffer_alignment))))
            push(field_reads,qmacro(fb_read(data,root,$v(f.id),$e(destination),$v(f.required))))
        } elif (f.offset64) {
            push(field_writes,qmacro(fb_write_wide(builder,$v(f.id),$e(source),$v(f.vector64))))
            push(field_reads,qmacro(fb_read_wide(data,root,$v(f.id),$e(destination),$v(f.required),$v(f.vector64))))
        } else {
            push(field_writes, qmacro(fb_write(builder, $v(f.id), $e(source))))
            push(field_reads, qmacro(fb_read(data, root, $v(f.id), $e(destination), $v(f.required))))
        }
        if (f.optional) {
            let payload = fb_ast_payload(field._type)
            let width = fb_inline_size(schema, f)
            var initial = qmacro(default<$t(payload)>)
            if (payload.isEnum) {
                let backing = new TypeDecl(baseType=payload.enumType.baseType)
                initial = qmacro(unsafe(reinterpret<$t(payload)>(default<$t(backing)>)))
            }
            let condition = f.boxed ? qmacro(length(obj.$f(native).value) != 0) : qmacro(obj.$f(native) is some)
            if (f.boxed) { push(writes, qmacro(fb_check_reference(length(obj.$f(native).value)))) }
            if(f.boxed && f.required){
                writes |> push <| qmacro_block() { if(empty(obj.$f(native).value)){panic("FlatBuffers: required reference is absent")} }
                push(reads,qmacro(fb_nested_position(data,root,$v(f.id),true,0)))
            }
            writes |> push <| qmacro_block() {
                if ($e(condition)) { $b(field_writes) }
            }
            let wrap = f.boxed ? qmacro(fb_move_ref(optional_value)) : qmacro(move_some(optional_value))
            reads |> push <| qmacro_block() {
                if (fb_field(data, root, $v(f.id), $v(width)) != 0) {
                    var optional_value = $e(initial)
                    $b(field_reads)
                    result.$f(native) <- $e(wrap)
                }
            }
        } else {
            if(!t.is_struct && fb_scalar(f.kind)){
                let fallback=field.init!=null ? clone_expression(field.init) : qmacro(default<$t(field._type)>)
                writes |> push <| qmacro_block() { if($e(source)!=$e(fallback)){ $b(field_writes) } }
            } else { for (expr in field_writes) { push(writes, expr) } }
            for (expr in field_reads) { push(reads, expr) }
        }
    }

    var offsets : array<int>
    resize(offsets, length(t.fields))
    for (f in t.fields) { offsets[f.id] = f.offset }
    let size = t.byte_size
    let ident = t.identifier
    var pack_fn : FunctionPtr
    var build_fn : FunctionPtr
    let build_name="fb_build_{st.name}"
    if (t.is_struct) {
        pack_fn = qmacro_function("unused") $(obj : $t(st); depth : int) : array<uint8> {
            fb_depth(depth)
            var builder : FBBuilder
            resize(builder.bytes, $v(size))
            $b(writes)
            return <- builder.bytes
        }
        let pack_name="fb_pack_depth_{st.name}"
        build_fn=qmacro_function("unused") $(obj:$t(st); var builder:FBBuilder; depth:int) : int {
            let bytes <- $c(pack_name)(obj,depth)
            fb_align(builder.bytes,$v(t.alignment))
            let at=length(builder.bytes)
            resize(builder.bytes,at+length(bytes))
            fb_copy_inline(builder.bytes,at,bytes)
            return at
        }
    } else {
        build_fn=qmacro_function("unused") $(obj:$t(st); var builder:FBBuilder; depth:int) : int {
            fb_depth(depth)
            var frame <- fb_enter(builder,$v(offsets),$v(size),$v(buffer_alignment))
            $b(writes)
            return fb_leave(builder,frame)
        }
        pack_fn = qmacro_function("unused") $(obj : $t(st); depth : int) : array<uint8> {
            var builder <- fb_header($v(ident))
            let root=$c(build_name)(obj,builder,depth)
            fb_put(builder.bytes,0,4,uint64(root))
            return <- builder.bytes
        }
    }
    var read_checks : array<ExpressionPtr>
    if (t.is_struct) { push(read_checks, qmacro(fb_bounds(data, root, $v(size)))) }
    else { push(read_checks, qmacro(fb_field(data, root, 0, 0))) }
    var unpack_fn = qmacro_function("unused") $(data : array<uint8>; root, depth : int) : $t(st) {
        fb_depth(depth)
        $b(read_checks)
        var result = default<$t(st)>
        $b(reads)
        return <- result
    }
    let pack_name = "fb_pack_depth_{st.name}"
    let read_name = "fb_unpack_at_{st.name}"
    var pack_wrapper = qmacro_function("unused") $(obj : $t(st)) : array<uint8> {
        return <- $c(pack_name)(obj, 0)
    }
    let root_expr = t.is_struct ? qmacro(0) : qmacro(fb_root(data, $v(ident)))
    var read_wrapper = qmacro_function("unused") $(data : array<uint8>) : $t(st) {
        return <- $c(read_name)(data, $e(root_expr), 0)
    }
    fb_replace_body(st, "fb_pack_{st.name}", pack_wrapper)
    fb_replace_body(st, "fb_unpack_{st.name}", read_wrapper)
    fb_replace_body(st, "fb_pack_depth_{st.name}", pack_fn)
    fb_replace_body(st,build_name,build_fn)
    fb_replace_body(st, "fb_unpack_at_{st.name}", unpack_fn)
    fb_replace_body(st, "fb_schema_{st.name}", schema_fn)
    fb_replace_body(st, "fb_descriptor_{st.name}", desc_fn)
    fb_replace_body(st, "fb_schema_ir_{st.name}", ir_fn)
    let wire_name=fb_qualified(t.name_space,t.name)
    let schema_name="fb_schema_ir_{st.name}"
    let pack_public="fb_pack_{st.name}"
    let object_index=fb_object_index(schema,wire_name)
    var view_fn=qmacro_function("unused") $(data:array<uint8>) : FBView {
        return FBView(present=true,kind=15,object_index=$v(object_index),position=$e(root_expr))
    }
    var verify_fn=qmacro_function("unused") $(data:array<uint8>) : bool {
        let schema <- $c(schema_name)()
        return fb_verify(data,schema,$v(wire_name))
    }
    var pack_size_fn=qmacro_function("unused") $(obj:$t(st)) : array<uint8> {
        return <- fb_size_prefixed($c(pack_public)(obj),$v(buffer_alignment),$v(prefix_width))
    }
    var read_size_fn=qmacro_function("unused") $(data:array<uint8>) : $t(st) {
        return <- $c(read_name)(data,fb_size_root(data,$v(ident),$v(prefix_width)),0)
    }
    fb_replace_body(st,"fb_view_{st.name}",view_fn)
    fb_replace_body(st,"fb_verify_{st.name}",verify_fn)
    fb_replace_body(st,"fb_pack_size_prefixed_{st.name}",pack_size_fn)
    fb_replace_body(st,"fb_unpack_size_prefixed_{st.name}",read_size_fn)
    var keys=0
    for(f in t.fields){
        if(!f.key){continue}
        keys++
        if(keys>1){panic("a table can have only one key")}
        let native=f.native_name
        var sort_fn=qmacro_function("fb_sort_{st.name}") $(var items:array<$t(st)>) {
            sort(items) $(a,b:$t(st)) : bool { return a.$f(native)<b.$f(native) }
        }
        fb_replace_body(st,"fb_sort_{st.name}",sort_fn)
    }
    args |> add_annotation_argument("__fb_done", true)
    astChanged = true
    return true
}

[structure_macro(name="fb_table")]
class FBTableMacro : AstStructureAnnotation {
    def override apply(var st : StructurePtr; var group : ModuleGroup; args : AnnotationArgumentList; var errors : das_string) : bool {
        return fb_macro_apply(st, args, errors, false)
    }
    def override patch(var st : StructurePtr; var group : ModuleGroup; var args : AnnotationArgumentList; var errors : das_string; var astChanged : bool&) : bool {
        return fb_macro_patch(st, args, astChanged)
    }
}
[structure_macro(name="fb_struct")]
class FBStructMacro : AstStructureAnnotation {
    def override apply(var st : StructurePtr; var group : ModuleGroup; args : AnnotationArgumentList; var errors : das_string) : bool {
        return fb_macro_apply(st, args, errors, true)
    }
    def override patch(var st : StructurePtr; var group : ModuleGroup; var args : AnnotationArgumentList; var errors : das_string; var astChanged : bool&) : bool {
        return fb_macro_patch(st, args, astChanged)
    }
}
[enumeration_macro(name="fb_enum")]
class FBEnumMacro : AstEnumerationAnnotation {
    def override apply(var enu : EnumerationPtr; var group : ModuleGroup; var args : AnnotationArgumentList; var errors : das_string) : bool {
        for (a in args) {
            if ((a.name != "namespace" && a.name != "name" && a.name!="names" && find(string(a.name),"attr_")!=0) || a.basicType != Type.tString) {
                errors := "fb_enum expects optional name/namespace strings"
                return false
            }
        }
        return true
    }
}
