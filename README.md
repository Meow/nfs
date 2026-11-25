# Nighty's Fast Serializer

NFS is a fast binary serializer for Garry's Mod, packaged for the Flux framework. It encodes
Lua values, entities, vectors, angles, matrices and colors into compact strings and decodes
them back. It continues [Srlion's Fast Serializer](https://github.com/Srlion/sfs) (SFS) and
keeps its API.

The encoder writes into a reused buffer of strings and concatenates it once, and the decoder
reads a table and every table inside it in a single loop. Both are written for the JIT
compilers of the three LuaJIT versions a server and its clients run (the server's 2.1, the
2.1.0-beta3 of 64-bit clients and the 2.0.4 of 32-bit clients): they tell values apart without
calling the engine's `type` and `isstring`, Lua functions at which LuaJIT ends the trace of the
caller, and they never concatenate strings, create closures or call `math.frexp` and
`math.ldexp` on the way of a value. Failures come back as `nil` and an error message.

NFS is written with the LuaJIT syntax extensions of the Flux runtime (`+=`, `!=`, `a ? b : c`,
`const`), which the server's `lua_shared` compiles and lowers to plain Lua for clients. It does
not load on a stock server.

## Installation

In a Flux project (a schema or a package that depends on NFS):

```sh
fpkg add nfs
```

That writes `s.depends 'nfs'` into the project's `packagespec.lua`, locks and installs. To work
on a local checkout instead, link it before adding:

```sh
fpkg link <path to this checkout>
fpkg add nfs
```

Once the package is installed, the library is in the `NFS` global on both realms. The package
also passes its path to clients as the `NFS_PATH` environment variable, so client code that runs
before packages load can include it directly:

```lua
NFS = NFS or include(getenv('NFS_PATH')..'lib/nfs.lua')
```

Outside a Flux project, `include` `lib/nfs.lua` on both realms (and `AddCSLuaFile` it on the
server). The file returns the library.

## Usage

```lua
local data, err = NFS.encode({ 1, 2, 3, name = 'value', pos = Vector(1, 2, 3) })

if !data then
  error(err)
end

local value, decode_err = NFS.decode(data)
```

`NFS.decode(data, max_size)` stops with `bytes overflow` once it would read past `max_size`
bytes. Data from clients is hostile: pass a `max_size` you are willing to process, and treat
an error return as a rejected message. `NFS.decode` never raises an error for the bytes it is
given: malformed data, data that is nested however deeply and errors raised by the decoders of
custom types all come back as `nil` and an error message.

`NFS.encode_to_hex(value)` and `NFS.decode_from_hex(str)` do the same with two hexadecimal
digits per byte, for places that only take printable text.

### Supported values

| Value | Encoded as |
|---|---|
| `nil`, `true`, `false` | the type id alone |
| integers | the type id alone from -54 to 100, else 1, 2, 4 or 7 bytes of magnitude below 2^56; -0 keeps its sign |
| other numbers | an IEEE 754 double, NaN and the infinities included |
| strings | the type id alone holds lengths up to 55, else a 1, 2 or 4 byte length, then the bytes |
| tables | an array while the keys run 1, 2, 3 and so on, a hash, or an array followed by a hash |
| `Entity`, `Weapon`, `Vehicle`, `NPC`, `NextBot` | the entity index in 2 bytes; NULL is kept apart from the world |
| `Player` | the entity index in 1 byte; a player that has left comes back as NULL |
| `Vector`, `Angle` | three single-precision floats |
| `VMatrix` | sixteen single-precision floats |
| `Color` | four bytes; channels are floored and kept within 0 and 255 |

Functions, and any other value without an encoder, fail with `unsupported type: <type>`.
Tables are encoded by their contents, so a table that contains itself overflows the stack.

The engine has the processor treat subnormal numbers (below 2^-1022) as zero, so in the game
such a number is encoded as the zero it compares equal to. Outside of the game it round-trips
exactly, like every other double.

### Custom types

`NFS.add_custom_type(type_key, encoder, decoder)` registers an encoder for a type name or a
metatable, gives it one of the 18 custom type ids and returns that id. The encoder writes the
id and then the value. The decoder skips the id and reads the value:

```lua
local Tag = {}
local tag_type

tag_type = NFS.add_custom_type(Tag, function(buf, tag)
  NFS.Encoder.write_byte(buf, tag_type)
  NFS.Encoder.encoders.string(buf, tag.name)
end, function(ctx)
  ctx[1] += 1

  local name, err = NFS.Decoder.decoders.string(ctx)

  if err then return nil, err end

  return setmetatable({ name = name }, Tag)
end)
```

Ids are handed out in the order the types are added, so both realms have to add the same
types in the same order. `NFS.set_custom_type_with_id(type_id, type_key, encoder, decoder)`
takes the id from the caller instead. It may take the id of a built-in type together with the
type itself, such as `NFS.TYPES.vector.start` for a `Vector` encoding of your own, but not the
ids of small integers, short strings, tables and `ending`, which the decoder reads in place:
those raise an error.

A custom type may also replace a built-in one by its type name (`'number'`, `'string'`,
`'table'`, `'Vector'` and so on). `NFS.encode` writes nil, booleans, numbers, strings and
tables without looking at `NFS.Encoder.encoders`, and finds engine values by their metatable;
adding the custom type switches that off for the type it replaces, while assigning into
`encoders` by hand does not.

A decoder that raises an error fails the decode with that error as the message.

An encoder returns `true` to fail, after writing the error message as the last two pieces of the
buffer with `NFS.Encoder.write_str`. A decoder returns the value, or `nil` and an error message.

### Building blocks

`NFS.Encoder` holds the writing functions (`write_byte`, `write_u16`, `write_u32`, `write_u53`,
their signed `write_i*` forms, `write_varint`, `write_float`, `write_double`, `write_str`,
`write_value`, `write_array`, `write_table`) and the `encoders` table by metatable and type
name. `NFS.Decoder` holds the matching `read_*` functions, `peak_type`, `setup_context` and the
`decoders` table by type id. `NFS.new_buffer`, `NFS.end_buffer` and `NFS.reset_buffer` make,
finish and empty a buffer of your own. `NFS.TYPES` lists the type id ranges by name.

`NFS.Encoder.encode` and `NFS.Decoder.decode` do not go through these functions themselves:
they pass the length of the buffer and the read position along as arguments, and fill index 0
of the buffer and the context only around the encoders and decoders of engine and custom
types. `NFS.encode` is reentrant, so an encoder may call it for a value of its own, and so is
`NFS.decode`.

`NFS.set_type_function(fn)` replaces the function the encoder names a value's type with. The
encoder only asks it about values that are not nil, a boolean, a number or a string and whose
metatable has no encoder. Until it is replaced the encoder does not call it for tables either:
it knows a table by `rawget` accepting it.

## Wire format

Every value starts with a one-byte type id. The ids are assigned in the order the library
declares its types. The format changes only with the major version: every minor and patch
release encodes exactly as its major's first release (8.x.x as 8.0.0), so a server whose
`lua_shared` has NFS 8.0.0 built in can keep it for any 8.x.x package. Encoded data should not
be stored for another major version to read. Multi-byte integers and floats are big-endian.

| Ids | Type | Follows the id |
|---|---|---|
| 0 to 100 | `positive_fixed` | nothing: the id is the integer |
| 101 to 156 | `string_fixed` | the bytes of a string of 0 to 55 bytes |
| 157 to 211 | `negative_fixed` | nothing: the integer is 157 minus the id, and 157 is -0 |
| 212, 213, 214 | `array`, `table`, `array_and_table` | values, pairs, or values, `ending` and pairs; then `ending` |
| 215 | `ending` | nothing |
| 216, 217, 218 | `nil`, `false`, `true` | nothing |
| 219 to 222 | `positive_u8` to `positive_u53` | the integer in 1, 2, 4 or 7 bytes |
| 223 to 226 | `negative_u8` to `negative_u53` | the magnitude in 1, 2, 4 or 7 bytes |
| 227, 228, 229 | `string_u8`, `string_u16`, `string_u32` | the length in 1, 2 or 4 bytes, then the bytes |
| 230, 231 | `float`, `double` | 4 or 8 bytes of IEEE 754 |
| 232, 233 | `entity`, `player` | the index in 2 bytes, two's complement, or in 1 byte |
| 234, 235 | `vector`, `angle` | three floats |
| 236, 237 | `matrix`, `color` | sixteen floats; four bytes |
| 238 to 255 | `custom` | whatever the encoder of the custom type writes |

The decoder tells the ranges up to `ending` apart by comparing ids, which is why they come
first. `NFS.TYPES` holds the same ranges by name at run time.

## Development

```sh
proofreader --format quiet .     # zero offenses
glua-check .                     # compiles under the server's LuaJIT
fpkg check                       # validates packagespec.lua
fpkg pack --list                 # what a release contains
```

## License

MIT, see [LICENSE](LICENSE). Copyright (c) 2024 Srlion, (c) 2026 Nighty.
