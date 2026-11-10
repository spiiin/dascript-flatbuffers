options gen2
require ./model.das
require ../src/runtime.das
require daslib/fio

[export]
def main {
    let args <- get_command_line_arguments()
    let out = args[length(args)-1]
    verify(fwrite(out + "/macro.fbs", fb_schema_Record()))
    var r = Record()
    r.enabled = false
    r.i8 = int8(-128)
    r.u8 = uint8(255)
    r.i16 = int16(-32768)
    r.u16 = uint16(65535)
    r.i32 = -2147483647
    r.u32 = 4294967295u
    r.i64 = -9223372036854775807l
    r.u64 = 18446744073709551615ul
    r.f32 = -3.5
    r.f64 = 1.2345678901234567lf
    r.text = "Hello, UTF-8: こんにちは 世界"
    r.flags <- [true, false, true]
    r.bytes <- [uint8(0), uint8(128), uint8(255)]
    r.signed_bytes <- [int8(-128), int8(0), int8(127)]
    r.shorts <- [int16(-32768), int16(32767)]
    r.ushorts <- [uint16(0), uint16(65535)]
    r.ints <- [-2147483647, 2147483647]
    r.uints <- [0u, 4294967295u]
    r.longs <- [-9223372036854775807l, 9223372036854775807l]
    r.ulongs <- [0ul, 18446744073709551615ul]
    r.floats <- [-3.5, 0.125]
    r.doubles <- [-1.2345678901234567lf, 1.0e100lf]
    r.removed = 999
    let b <- fb_pack_Record(r)
    fb_save(out + "/from_das.bin", b)
    let q <- fb_unpack_Record(b)
    assert(q.text == r.text && q.u64 == r.u64 && q.i8 == r.i8)
    assert(q.doubles[1] == r.doubles[1] && !q.enabled && q.removed == 0)
    if (fexist(out + "/from_flatc.bin")) {
        let ext <- fb_load(out + "/from_flatc.bin")
        let value <- fb_unpack_Record(ext)
        assert(value.text == r.text && value.u64 == r.u64 && value.i64 == r.i64)
        assert(value.i8 == r.i8 && value.i16 == r.i16 && value.u32 == r.u32)
        assert(value.f64 == r.f64 && value.doubles[1] == r.doubles[1])
        assert(length(value.bytes) == 3 && value.bytes[2] == uint8(255))
        assert(!value.flags[1] && value.longs[0] == r.longs[0])
        fb_save(out + "/flatc_repacked.bin", fb_pack_Record(value))
    }
    if (fexist(out + "/defaults.bin")) {
        let ext <- fb_load(out + "/defaults.bin")
        let d <- fb_unpack_Record(ext)
        assert(d.enabled && d.i8 == int8(-12) && d.u8 == uint8(250) && d.i16 == int16(-1234))
        assert(d.u16 == uint16(60000) && d.i32 == -1234567 && d.u32 == 4000000000u)
        assert(d.i64 == -9000000000000000000l && d.u64 == 9000000000000000000ul)
        assert(d.f32 == 1.25 && d.f64 == 1.23456789012345lf)
        assert(empty(d.text) && empty(d.bytes))
    }
    print("macro interop OK\n")
}
