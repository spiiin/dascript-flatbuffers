options gen2
module nested_model public
require ../src/annotations.das public

[fb_enum(namespace="world")]
enum Color : int16 { Red = -3
None = 0
Green = 2
Blue = 300 }
[fb_enum(namespace="world")]
enum Tiny : uint8 { None = 0
Max = 255 }
[fb_enum(namespace="world")]
enum Wide : uint64 { None = 0ul
High = 18446744073709551615ul }

[fb_struct(namespace="world")]
struct Vec {
    x : float
    tag : uint8
    color : Color
}
[fb_struct(namespace="world", align=16)]
struct Pose {
    tag : uint8
    pos : Vec
    weight : double
    code : int16
}
[fb_table(namespace="world")]
struct Item {
    @fb_id=0
    name : string
    @fb_id=1
    power : int = 7
    @fb_id=2
    color : Color = Color.Green
}
[fb_table(namespace="world")]
struct Loadout {
    @fb_id=0
    @fb_required
    item : Item
    @fb_id=1
    history : array<Item>
}
[fb_table(namespace="world", root=true, identifier="NEST")]
struct Scene {
    @fb_id=0
    loadout : Loadout
    @fb_id=1
    pose : Pose
    @fb_id=2
    items : array<Item>
    @fb_id=3
    poses : array<Pose>
    @fb_id=4
    color : Color = Color.Blue
    @fb_id=5
    colors : array<Color>
    @fb_id=6
    tiny : Tiny = Tiny.Max
    @fb_id=7
    wide : Wide = Wide.None
    @fb_id=8
    wides : array<Wide>
}
