# Nighty's Fast Serializer

NFS is a fast binary serializer for Garry's Mod, packaged for the Flux framework. It encodes
Lua values, entities, vectors, angles, matrices and colors into compact strings and decodes
them back. It continues [Srlion's Fast Serializer](https://github.com/Srlion/sfs) (SFS) and
keeps its API.

The encoder writes into a reused buffer of strings and concatenates it once. It reports
failures by returning values instead of raising errors or concatenating strings, so the JIT
compiler compiles every step of an encode. Failures come back as `nil` and an error message.

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
an error return as a rejected message.

`NFS.encode_to_hex(value)` and `NFS.decode_from_hex(str)` do the same with two hexadecimal
digits per byte, for places that only take printable text.

### Supported values

| Value | Encoded as |
|---|---|
| `nil`, `true`, `false` | the type id alone |
| integers | the type id alone from -54 to 100, else 1, 2, 4 or 7 bytes of magnitude; -0 keeps its sign |
| other numbers | an IEEE 754 double, NaN and the infinities included |
| strings | the type id alone holds lengths up to 55, else a 1, 2 or 4 byte length, then the bytes |
| tables | an array while the keys run 1, 2, 3 and so on, a hash, or an array followed by a hash |
| `Entity`, `Weapon`, `Vehicle`, `NPC`, `NextBot` | the entity index in 2 bytes; NULL is kept apart from the world |
| `Player` | the entity index in 1 byte |
| `Vector`, `Angle` | three single-precision floats |
| `VMatrix` | sixteen single-precision floats |
| `Color` | four bytes |

Functions, and any other value without an encoder, fail with `unsupported type: <type>`.
Tables are encoded by their contents, so a table that contains itself overflows the stack.

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
takes the id from the caller instead.

An encoder returns `true` to fail, after writing the error message as the last two pieces of the
buffer with `NFS.Encoder.write_str`. A decoder returns the value, or `nil` and an error message.

### Building blocks

`NFS.Encoder` holds the writing functions (`write_byte`, `write_u16`, `write_u32`, `write_u53`,
their signed `write_i*` forms, `write_varint`, `write_float`, `write_double`, `write_str`,
`write_value`, `write_array`, `write_table`) and the `encoders` table by metatable and type
name. `NFS.Decoder` holds the matching `read_*` functions, `peak_type`, `setup_context` and the
`decoders` table by type id. `NFS.new_buffer`, `NFS.end_buffer` and `NFS.reset_buffer` make,
finish and empty a buffer of your own. `NFS.TYPES` lists the type id ranges by name.

`NFS.set_type_function(fn)` replaces the function the encoder names a value's type with, for
a type function that the JIT compiler compiles where the engine's own does not.

## Wire format

Every value starts with a one-byte type id. The ids are assigned in the order the library
declares its types, so the format is only stable within one version of NFS. Client and server
run the same copy, which keeps them in sync, but encoded data should not be stored for a later
version to read. Multi-byte integers and floats are big-endian.

## Development

```sh
proofreader --format quiet .     # zero offenses
glua-check .                     # compiles under the server's LuaJIT
fpkg check                       # validates packagespec.lua
fpkg pack --list                 # what a release contains
```

## License

MIT, see [LICENSE](LICENSE). Copyright (c) 2024 Srlion, (c) 2026 Nighty.
