options gen2
module verifier public
require ./views.das public

struct FBVerifyOptions { max_depth:int=64; max_objects:int=1000000; utf8:bool=true; alignment:bool=true }
def fb_verify_alignment(position,alignment:int; limits:FBVerifyOptions){
    if(limits.alignment && position%alignment!=0){panic("FlatBuffers: misaligned value")}
}
def fb_verify_utf8(data:array<uint8>; start,count:int){
    fb_bounds(data,start,count)
    var i=0
    while(i<count){
        let c=uint(data[start+i]);i++
        if(c<128u){continue}
        var more=0
        var cp=0u
        var minimum=0u
        if(c>=194u && c<=223u){more=1;cp=c&31u;minimum=128u}
        elif(c>=224u && c<=239u){more=2;cp=c&15u;minimum=2048u}
        elif(c>=240u && c<=244u){more=3;cp=c&7u;minimum=65536u}
        else{panic("FlatBuffers: invalid UTF-8 lead byte")}
        if(more>count-i){panic("FlatBuffers: truncated UTF-8")}
        for(j in range(more)){
            let next=uint(data[start+i]);i++
            if((next&192u)!=128u){panic("FlatBuffers: invalid UTF-8 continuation")}
            cp=(cp<<6u)|(next&63u)
        }
        if(cp<minimum || cp>1114111u || (cp>=55296u && cp<=57343u)){panic("FlatBuffers: invalid UTF-8 code point")}
    }
}
def fb_verify_value(data:array<uint8>; schema:FBSchema; view:FBView; limits:FBVerifyOptions; depth:int; var objects:int&; region_start,region_end:int){
    if(!view.present){return}
    // An empty vector's first-element position may equal the buffer end.
    if(view.position<region_start || view.position>region_end ||
        (view.position==region_end && !(view.kind==14 && view.count==0))){panic("FlatBuffers: value outside buffer region")}
    if(depth>limits.max_depth){panic("FlatBuffers: verification depth limit")}
    objects++
    if(objects>limits.max_objects){panic("FlatBuffers: verification object limit")}
    if(view.kind==15){
        if(view.object_index<0){panic("FlatBuffers: invalid object metadata")}
        assume object=schema.tables[view.object_index]
        fb_verify_alignment(view.position,object.is_struct ? object.alignment : 4,limits)
        if(object.is_struct){
            fb_bounds(data,view.position,object.byte_size)
            if(object.byte_size>region_end-view.position){panic("FlatBuffers: struct outside buffer region")}
        } else {
            fb_field(data,view.position,0,0)
            let vt=view.position-int(fb_uint(data,view.position,4))
            let vsize=int(fb_uint(data,vt,2))
            let osize=int(fb_uint(data,vt+2,2))
            fb_verify_alignment(vt,2,limits)
            if(vt<region_start || vsize>region_end-vt || osize>region_end-view.position){panic("FlatBuffers: table outside buffer region")}
        }
        for(f in object.fields){
            if(f.deprecated || f.kind==1 || (f.kind==14 && f.element==1)){continue}
            let child=fb_view_field(data,schema,view,f.id)
            if(child.present){
                let slot=object.is_struct ? view.position+f.offset : fb_field(data,view.position,f.id,fb_inline_size(schema,f))
                fb_verify_alignment(slot,fb_inline_alignment(schema,f),limits)
            }
            fb_verify_value(data,schema,child,limits,depth+1,objects,region_start,region_end)
            if(child.present && !empty(f.nested_buffer)){
                let nested=fb_view_nested(data,schema,child,f.nested_buffer)
                fb_verify_value(data,schema,nested,limits,depth+1,objects,child.position,child.position+child.count)
            }
        }
    } elif(view.kind==13){
        fb_verify_alignment(view.position,4,limits)
        fb_bounds(data,view.position+4,view.count+1)
        if(view.count+5>region_end-view.position){panic("FlatBuffers: string outside buffer region")}
        if(data[view.position+4+view.count]!=0u8){panic("FlatBuffers: string missing terminator")}
        if(limits.utf8){fb_verify_utf8(data,view.position+4,view.count)}
    } elif(view.kind==14 || view.kind==17){
        if(view.position-view.header<region_start || view.count*view.stride>region_end-view.position){panic("FlatBuffers: vector outside buffer region")}
        if(view.union_tags!=0 && (view.union_tags<region_start || view.count>region_end-view.union_tags)){panic("FlatBuffers: union tags outside buffer region")}
        let alignment=view.element==15 ? (schema.tables[view.object_index].is_struct ? schema.tables[view.object_index].alignment : 4) : fb_width(view.element)
        fb_verify_alignment(view.position,alignment,limits)
        for(i in range(view.count)){fb_verify_value(data,schema,fb_view_element(data,schema,view,i),limits,depth+1,objects,region_start,region_end)}
    } else {
        let width=fb_width(view.kind)
        if(width==0){panic("FlatBuffers: invalid scalar kind")}
        fb_verify_alignment(view.position,width,limits)
        fb_bounds(data,view.position,width)
        if(width>region_end-view.position){panic("FlatBuffers: scalar outside buffer region")}
    }
}
def fb_verify_or_panic(data:array<uint8>; schema:FBSchema; type_name:string; size_prefixed:bool=false; limits:FBVerifyOptions=FBVerifyOptions()){
    var count=0
    let root=fb_view_root(data,schema,type_name,size_prefixed)
    fb_verify_value(data,schema,root,limits,0,count,0,length(data))
}
def fb_verify(data:array<uint8>; schema:FBSchema; type_name:string; size_prefixed:bool=false; limits:FBVerifyOptions=FBVerifyOptions()) : bool {
    var valid=false
    try {
        fb_verify_or_panic(data,schema,type_name,size_prefixed,limits)
        valid=true
    } recover { valid=false }
    return valid
}
