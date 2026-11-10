options gen2
require ../src/annotations.das

[fb_table]
struct Item {
    @fb_id=0
    power : int = 7
    @fb_id=1
    tags : array<int>
}

[fb_table(root=true, identifier="OPTL")]
struct Equipment {
    @fb_id=0
    equipped : Option<Item>
}

[export]
def main {
    var equipment = Equipment()
    let absent <- fb_unpack_Equipment(fb_pack_Equipment(equipment))
    assert(absent.equipped is none)

    equipment.equipped <- some(Item())
    let defaults <- fb_unpack_Equipment(fb_pack_Equipment(equipment))
    assert(defaults.equipped is some && (defaults.equipped as some).power == 7)

    var item = Item(power=42)
    item.tags <- [1,2,3]
    equipment.equipped <- move_some(item)
    let present <- fb_unpack_Equipment(fb_pack_Equipment(equipment))
    assert(present.equipped is some)
    print("power = {(present.equipped as some).power}\n")

    equipment.equipped <- none(type<Item>)
    let cleared <- fb_unpack_Equipment(fb_pack_Equipment(equipment))
    assert(cleared.equipped is none)
    print(fb_schema_Equipment())
}
