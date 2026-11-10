options gen2
require ./nested_model.das
require ../src/runtime.das
require daslib/fio
[export]
def main {
    let args <- get_command_line_arguments()
    let folder = args[length(args)-1]
    var s = Scene()
    s.loadout.item.name = "Sword"
    s.loadout.item.power = 99
    s.loadout.item.color = Color.Red
    var spare = Item()
    spare.name = "Shield"
    spare.power = -5
    spare.color = Color.Blue
    push_clone(s.items, spare)
    push_clone(s.loadout.history, spare)
    s.pose.tag = uint8(255)
    s.pose.pos.x = 3.5
    s.pose.pos.tag = uint8(17)
    s.pose.pos.color = Color.Blue
    s.pose.weight = 1.2345678901234567lf
    s.pose.code = int16(-1234)
    push(s.poses, s.pose)
    s.color = Color.Red
    s.colors <- [Color.Red, Color.Green, Color.Blue]
    s.tiny = Tiny.Max
    s.wide = Wide.High
    s.wides <- [Wide.None, Wide.High]
    let bytes <- fb_pack_Scene(s)
    fb_save(folder + "/nested_das.bin", bytes)
    let back <- fb_unpack_Scene(bytes)
    assert(back.loadout.item.name == "Sword" && back.items[0].power == -5)
    assert(back.pose.code == int16(-1234) && back.poses[0].pos.color == Color.Blue)
    assert(back.wide == Wide.High && back.colors[0] == Color.Red)
    verify(fwrite(folder + "/nested_macro.fbs", fb_schema_Scene()))
    let ir <- fb_schema_ir_Scene()
    assert(length(ir.tables) == 5 && length(ir.enums) == 3)
    if (fexist(folder + "/nested_flatc.bin")) {
        let b <- fb_load(folder + "/nested_flatc.bin")
        let value <- fb_unpack_Scene(b)
        assert(value.loadout.item.name == "Sword" && value.items[0].power == -5)
        assert(value.pose.weight == 1.2345678901234567lf)
        assert(value.poses[0].pos.color == Color.Blue && value.pose.code == int16(-1234))
        assert(value.wide == Wide.High && value.wides[1] == Wide.High && value.tiny == Tiny.Max)
        fb_save(folder + "/nested_repacked.bin", fb_pack_Scene(value))
    }
    print("nested macro OK\n")
}
