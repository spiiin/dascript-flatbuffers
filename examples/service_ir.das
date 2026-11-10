options gen2
require ../src/annotations.das
require ../src/bfbs.das
require daslib/fio

[fb_table(root=true)]
struct Request { @fb_id=0
    value:int
}
[fb_table]
struct Response { @fb_id=0
    value:int
}

// Run with: -- generated
// Generates annotated types and a transport-independent fb_rpc_Echo_Call client.
[export]
def main {
    let args <- get_command_line_arguments()
    let folder=args[length(args)-1]
    var schema <- fb_schema_ir_Request()
    var response <- fb_descriptor_Response()
    emplace(schema.tables,response)
    var service=FBService(name="Echo")
    emplace(service.calls,FBRpcCall(name="Call",request="Request",response="Response"))
    emplace(schema.services,service)
    verify(fwrite(folder+"/service.fbs",fb_emit_schema(schema)))
    verify(fwrite(folder+"/service.das",fb_emit_das(schema,"service","../src/annotations.das")))
}
