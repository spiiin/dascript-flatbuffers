options gen2
module references public
require daslib/templates
require daslib/templates_boost
require daslib/typemacro_boost

// Owning, nullable table reference. Indirection permits recursive native types.
// A zero/one-element array has deterministic ownership and no reference cycles.
[template_structure(T)]
struct template FBRef {
    @fb_reference
    value : array<T>
}
def fb_ref(v:auto(T)) {
    var result : $FBRef<T -const>
    push_clone(result.value, v)
    return <- result
}
def fb_move_ref(var v:auto(T)) {
    var result : $FBRef<T -const>
    emplace(result.value, v)
    return <- result
}
def fb_has_ref(v:$FBRef<auto(T)>) : bool => length(v.value) == 1
def fb_clear_ref(var v:$FBRef<auto(T)>) { clear(v.value) }
