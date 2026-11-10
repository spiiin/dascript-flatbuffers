options gen2
module union_codegen public
require strings
require daslib/ast
require daslib/ast_boost
require daslib/templates_boost
require ./ast_adapter.das

def fb_union_construct(typ:TypeDeclPtr; member:string; value:ExpressionPtr) : ExpressionPtr {
    var mk = new ExprMakeVariant(makeType=clone_type(typ))
    var field = new MakeFieldDecl(name:=member,value=clone_expression(value))
    field.flags = MakeFieldDeclFlags.moveSemantics
    emplace(mk.variants,field)
    return mk
}
def fb_union_helper(st:StructurePtr; prefix:string) : string {
    return empty(st._module.name) ? "{prefix}_{st.name}" : "{st._module.name}::{prefix}_{st.name}"
}
def fb_union_codegen(s:FBSchema; f:FBField; td:TypeDeclPtr; source,destination:ExpressionPtr;
    var writes,reads:array<ExpressionPtr>) {
    let typ = f.kind == 14 ? td.firstType : td
    assume en = s.enums[fb_enum_index(s,f.type_name)]
    let align = fb_buffer_alignment(s)
    var encode : array<ExpressionPtr>
    var decode : array<ExpressionPtr>
    for (i in range(1,length(typ.argTypes))) {
        let member = string(typ.argNames[i])
        let native_payload=typ.argTypes[i]
        let payload_type = fb_ast_payload(native_payload)
        let boxed=fb_ast_is_box(native_payload)
        let tag = uint8(int(en.values[i].value))
        var pack_expr : ExpressionPtr
        var read_expr : ExpressionPtr
        var payload_kind = 13
        if (payload_type.baseType == Type.tString) {
            pack_expr = qmacro(fb_append_text(builder.bytes,union_value as $f(member)))
            read_expr = qmacro(fb_string_at(data,union_location.position))
        } else {
            let st = payload_type.structType
            let meta <- fb_ast_meta(st)
            payload_kind = meta.is_struct ? 17 : 15
            let pack = fb_union_helper(st,"fb_build")
            let read = fb_union_helper(st,"fb_unpack_at")
            let payload=boxed ? qmacro((union_value as $f(member)).value[0]) : qmacro(union_value as $f(member))
            pack_expr = qmacro($c(pack)($e(payload),builder,depth+1))
            read_expr = qmacro($c(read)(data,union_location.position,depth+1))
        }
        var validate:array<ExpressionPtr>
        if(boxed){validate |> push <| qmacro_block() { if(length((union_value as $f(member)).value)!=1){panic("FlatBuffers: active union requires a reference payload")} } }
        encode |> push <| qmacro_block() {
            if (union_value is $f(member)) {
                $b(validate)
                encoded.tag = $v(tag)
                encoded.kind = $v(payload_kind)
                encoded.position = $e(pack_expr)
            }
        }
        let wrapped=boxed ? qmacro(fb_move_ref(union_payload)) : qmacro(union_payload)
        let construct = fb_union_construct(typ,member,wrapped)
        var initialize : ExpressionPtr
        if (payload_type.baseType == Type.tString) {
            let init_block = qmacro_block() { var union_payload = $e(read_expr) }
            initialize = clone_expression((init_block as ExprBlock).list[0])
        } else {
            let init_block = qmacro_block() { var union_payload <- $e(read_expr) }
            initialize = clone_expression((init_block as ExprBlock).list[0])
        }
        decode |> push <| qmacro_block() {
            if (union_location.tag == $v(tag)) {
                $e(initialize)
                union_result <- $e(construct)
                union_known = true
            }
        }
    }
    if (f.kind == 14) {
        writes |> push <| qmacro_block() {
            let union_slots=fb_begin_unions(builder,$v(f.id),length($e(source)))
            for (union_index in range(length($e(source)))) {
                assume union_value=$e(source)[union_index]
                var encoded : FBUnionEncoded
                $b(encode)
                fb_set_union(builder,union_slots,union_index,encoded,$v(align))
            }
        }
        reads |> push <| qmacro_block() {
            let locations <- fb_union_locations(data,root,$v(f.id),$v(f.required))
            for (union_location in locations) {
                var union_result = default<$t(typ)>
                var union_known = union_location.tag == 0u8
                $b(decode)
                if (!union_known) { panic("FlatBuffers: unknown union tag") }
                emplace($e(destination),union_result)
            }
        }
    } else {
        writes |> push <| qmacro_block() {
            assume union_value = $e(source)
            var encoded : FBUnionEncoded
            $b(encode)
            fb_write_union(builder,$v(f.id),encoded,$v(align),$v(f.required))
        }
        reads |> push <| qmacro_block() {
            let union_location = fb_union_location(data,root,$v(f.id),$v(f.required))
            var union_result = default<$t(typ)>
            var union_known = union_location.tag == 0u8
            $b(decode)
            if (!union_known) { panic("FlatBuffers: unknown union tag") }
            $e(destination) <- union_result
        }
    }
}
