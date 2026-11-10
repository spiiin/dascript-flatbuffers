options gen2
require ../src/annotations.das

[fb_enum(namespace="game")]
enum Rarity : uint8 {
    Common = 0
    Rare = 1
}
[fb_struct(namespace="game", align=16)]
struct Position {
    x : double
    y : float
    tag : uint8
}
[fb_table(namespace="game")]
struct Item {
    @fb_id=0
    name : string
    @fb_id=1
    rarity : Rarity = Rarity.Common
}
[fb_table(namespace="game", root=true, identifier="HERO")]
struct Hero {
    @fb_id=0
    position : Position
    @fb_id=1
    equipped : Item
    @fb_id=2
    inventory : array<Item>
    @fb_id=3
    trail : array<Position>
}
[export]
def main {
    var hero = Hero()
    hero.equipped.name = "Sword"
    hero.equipped.rarity = Rarity.Rare
    hero.position.x = 1.25lf
    hero.position.y = 3.5
    push_clone(hero.inventory, hero.equipped)
    push(hero.trail, hero.position)
    let bytes <- fb_pack_Hero(hero)
    let restored <- fb_unpack_Hero(bytes)
    assert(restored.inventory[0].rarity == Rarity.Rare)
    assert(restored.trail[0].x == 1.25lf)
    print(fb_schema_Hero())
}
