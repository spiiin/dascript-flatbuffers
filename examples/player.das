options gen2
require ../src/annotations.das

[fb_table(root=true, namespace="game", identifier="PLYR")]
struct Player {
    @fb_id = 0
    name : string
    @fb_id = 1
    hp : int = 100
    @fb_id = 2
    inventory : array<uint8>
}
[export]
def main {
    var p = Player()
    p.name = "Alice"
    p.hp = 42
    p.inventory <- [1u8, 2u8, 255u8]
    let b <- fb_pack_Player(p)
    let q <- fb_unpack_Player(b)
    assert(q.name == "Alice" && q.hp == 42 && q.inventory[2] == 255u8)
    let t <- fb_descriptor_Player()
    assert(length(t.fields) == 3)
    print(fb_schema_Player())
}
