options gen2
require ../src/bfbs.das
require ../src/runtime.das
require daslib/strings_boost
require daslib/fio

[export]
def main {
    let all <- get_command_line_arguments()
    var args : array<string>
    var user_args = false
    for (a in all) {
        if (user_args) { push(args, a) }
        if (a == "--") { user_args = true }
    }
    if (length(args) < 3 || length(args) > 4) {
        panic("usage: daslang tools/generate.das -- input.bfbs output.das normalized.fbs [annotation-import]")
    }
    let b <- fb_load(args[0])
    let schema <- fb_import_bfbs(b)
    let slash = rfind(replace(args[1], "\\", "/"), "/")
    let filename = slice(args[1], slash+1)
    let dot = rfind(filename, ".")
    let module_name = dot < 0 ? filename : slice(filename, 0, dot)
    let import_path = length(args) == 4 ? args[3] : "../src/annotations.das"
    let code = fb_emit_das(schema, module_name, import_path)
    let fbs = fb_emit_schema(schema)
    if (!fwrite(args[1], code) || !fwrite(args[2], fbs)) { panic("failed to write generated output") }
}
