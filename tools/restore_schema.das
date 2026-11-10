options gen2
require ../src/bfbs.das
require ../src/runtime.das
require strings
require daslib/fio
require daslib/strings_boost

def relative_source(path:string) : string {
    var value=replace(path,"\\","/")
    while(find(value,"/")==0){value=slice(value,1)}
    if(empty(value) || find(value,":")>=0){panic("source metadata must contain relative filenames; use flatc --bfbs-filenames")}
    for(part in split(value,"/")){if(part==".." || part=="."){panic("source path traversal is not allowed")}}
    return value
}
def relative_include(from_file,to_file:string) : string {
    let from <- split(from_file,"/")
    let target <- split(to_file,"/")
    var common=0
    while(common<length(from)-1 && common<length(target)-1 && from[common]==target[common]){common++}
    var result=""
    for(i in range(common,length(from)-1)){result+="../"}
    for(i in range(common,length(target))){if(i>common){result+="/"};result+=target[i]}
    return result
}
[export]
def main {
    let args <- get_command_line_arguments()
    if(length(args)<4){panic("usage: restore_schema.das -- input.bfbs output-directory")}
    let input=args[length(args)-2]
    let directory=args[length(args)-1]
    let schema <- fb_import_bfbs(fb_load(input))
    if(empty(schema.sources)){panic("BFBS has no source file metadata")}
    // Validate and render the whole bundle before touching output paths.
    var paths:array<string>
    var contents:array<string>
    for(source in schema.sources){
        let path=relative_source(source.filename)
        var text=""
        for(dependency in source.includes){text+="include "+fb_quote(relative_include(path,relative_source(dependency)))+";\n"}
        text+=fb_emit_schema(schema,source.filename)
        push(paths,directory+"/"+path)
        push(contents,text)
    }
    for(i in range(length(paths))){
        let parent=slice(paths[i],0,rfind(paths[i],"/"))
        verify(mkdir_rec(parent))
        verify(fwrite(paths[i],contents[i]))
    }
}
