options gen2
module optional_model public
require ../src/annotations.das public

[fb_table(namespace="presence")]
struct Leaf {
    @fb_id=0
    value : int = 11
}
[fb_table(namespace="presence")]
struct Child {
    @fb_id=0
    power : int = 7
    @fb_id=1
    values : array<int>
    @fb_id=2
    leaf : Option<Leaf>
}
[fb_table(namespace="presence", root=true, identifier="OPTN")]
struct Envelope {
    @fb_id=0
    child : Option<Child>
    @fb_id=1
    @fb_required
    mandatory : Child
    @fb_id=2
    children : array<Child>
    @fb_id=3
    sibling : Option<Child>
}
