options gen2
module model public
require ../src/annotations.das public

[fb_table(root=true, namespace="compat", identifier="TEST")]
struct Record {
    @fb_id = 0
    enabled : bool = true
    @fb_id = 1
    i8 : int8 = -12
    @fb_id = 2
    u8 : uint8 = 250
    @fb_id = 3
    i16 : int16 = -1234
    @fb_id = 4
    u16 : uint16 = 60000
    @fb_id = 5
    i32 : int = -1234567
    @fb_id = 6
    u32 : uint = 4000000000u
    @fb_id = 7
    i64 : int64 = -9000000000000000000l
    @fb_id = 8
    u64 : uint64 = 9000000000000000000ul
    @fb_id = 9
    f32 : float = 1.25
    @fb_id = 10
    f64 : double = 1.23456789012345lf
    @fb_id = 11
    text : string
    @fb_id = 12
    flags : array<bool>
    @fb_id = 13
    bytes : array<uint8>
    @fb_id = 14
    signed_bytes : array<int8>
    @fb_id = 15
    shorts : array<int16>
    @fb_id = 16
    ushorts : array<uint16>
    @fb_id = 17
    ints : array<int>
    @fb_id = 18
    uints : array<uint>
    @fb_id = 19
    longs : array<int64>
    @fb_id = 20
    ulongs : array<uint64>
    @fb_id = 21
    floats : array<float>
    @fb_id = 22
    doubles : array<double>
    @fb_id = 23
    @fb_deprecated
    removed : int
}
