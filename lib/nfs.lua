--- Nighty's Fast Serializer, a continuation of Srlion's Fast Serializer: encodes Lua and engine
-- values into compact binary strings and decodes them back.
--
-- Every value starts with a one-byte type id. Small integers and short strings are stored in the
-- id itself, larger ones are followed by their magnitude or length in 1, 2, 4 or 7 big-endian
-- bytes. Floats and doubles are IEEE 754 in big-endian order. A table is an array, a hash or an
-- array followed by a hash, each closed by the `ending` id. Entities are written by their index,
-- players by their index in one byte, vectors and angles as three floats, matrices as sixteen
-- floats and colors as four bytes. Functions and other values without an encoder fail to encode.
--
-- Failures are returned as nil and an error message. The encoder writes into a buffer of strings
-- that is concatenated once at the end, and it reports failures without raising errors or
-- concatenating strings, so the JIT compiler of LuaJIT 2.0 compiles all of it.
-- ```
-- local data = NFS.encode({ 1, 2, 3, name = 'value' })
-- local value, err = NFS.decode(data)
-- ```
-- @module [NFS]

const pairs = pairs
const getmetatable = getmetatable
const tostring = tostring
const table_concat = table.concat
const math_floor = math.floor
const math_ldexp = math.ldexp
const math_frexp = math.frexp
const INFINITY = math.huge

--- The function the encoder names the type of a value with. `NFS.set_type_function` replaces it.
local type = type

--- One-character strings of every byte, indexed by the byte. The encoder looks them up instead
-- of calling `string.char`, which the JIT compiler of LuaJIT 2.0 does not compile.
const chars = {}

for i = 0, 255 do
  chars[i] = string.char(i)
end

--- Ranges of type ids by type name: `start` is the first id of a range and `max` the highest
-- offset from it. Ids are handed out in the order of the `new_type` calls below, so data only
-- decodes with the version of NFS that encoded it.
const TYPES = {}

local type_count = -1

--- Reserves a range of consecutive type ids and records it in `TYPES`.
-- @param name [String name of the type]
-- @param n=1 [Number amount of ids to reserve]
-- @return [Number first id of the range, Number highest offset from the first id]
local function new_type(name, n)
  n = n or 1

  if type_count + n > 255 then
    error('types count cannot be more than 256', 2)
  end

  local start_type = type_count + 1
  type_count += n

  TYPES[name] = {
    start = start_type,
    max = n - 1
  }

  return start_type, n - 1
end

const NIL                                      = new_type('nil')
const FALSE                                    = new_type('false')
const TRUE                                     = new_type('true')

const FLOAT                                    = new_type('float')
const DOUBLE                                   = new_type('double')

const ENTITY                                   = new_type('entity')
const PLAYER                                   = new_type('player')
const VECTOR                                   = new_type('vector')
const ANGLE                                    = new_type('angle')
const MATRIX                                   = new_type('matrix')
const COLOR                                    = new_type('color')

const POSITIVE_FIXED_START, POSITIVE_FIXED_MAX = new_type('positive_fixed', 101)
const POSITIVE_U8                              = new_type('positive_u8')
const POSITIVE_U16                             = new_type('positive_u16')
const POSITIVE_U32                             = new_type('positive_u32')
const POSITIVE_U53                             = new_type('positive_u53')

const NEGATIVE_FIXED_START, NEGATIVE_FIXED_MAX = new_type('negative_fixed', 55)
const NEGATIVE_U8                              = new_type('negative_u8')
const NEGATIVE_U16                             = new_type('negative_u16')
const NEGATIVE_U32                             = new_type('negative_u32')
const NEGATIVE_U53                             = new_type('negative_u53')

const STRING_FIXED_START, STRING_FIXED_MAX     = new_type('string_fixed', 56)
const STRING_U8                                = new_type('string_u8')
const STRING_U16                               = new_type('string_u16')
const STRING_U32                               = new_type('string_u32')

const ARRAY                                    = new_type('array')
const TABLE                                    = new_type('table')
const ARRAY_AND_TABLE                          = new_type('array_and_table')
const ENDING                                   = new_type('ending')

const CUSTOM_START, CUSTOM_MAX                 = new_type('custom', 18)

--- Index written for NULL, the lowest 16-bit integer: NULL and the world both have index 0, and
-- entities that are not networked have index -1.
const NULL_ENT_INDEX = -0x8000

--- Set of the type ids of strings.
const STRING_TYPES = {
  [STRING_U8] = true,
  [STRING_U16] = true,
  [STRING_U32] = true
}

for i = 0, STRING_FIXED_MAX do
  STRING_TYPES[STRING_FIXED_START + i] = true
end

const encoders = {}

--- The encoding half of NFS. A buffer is a list of strings with its length at index 0, and an
-- encoding function writes into it and returns true when it fails, leaving the error message in
-- the last two pieces of the buffer. `encoders` holds the encoding function of every metatable
-- and type name, and `ENDING` is the id that closes arrays and tables, which custom types may
-- use to close lists of their own.
const Encoder = {
  encoders = encoders,
  ENDING = ENDING
}

do
  --- Appends a string to a buffer.
  -- @param buf [List<String> buffer to write to]
  -- @param str [String string to append]
  function Encoder.write_str(buf, str)
    local buf_len = buf[0] + 1
    buf[0] = buf_len
    buf[buf_len] = str
  end

  local write_str = Encoder.write_str

  --- Returns the encoding function of a value's metatable or, without one, of its type.
  -- @param val [Any value to encode]
  -- @return [Function encoding function, nil when the value cannot be encoded]
  function Encoder.get_encoder_impl(val)
    local encoder = encoders[getmetatable(val)]

    if encoder == nil then
      encoder = encoders[type(val)]
    end

    return encoder
  end

  local get_encoder_impl = Encoder.get_encoder_impl

  --- Returns the encoding function of a value, writing an error message into the buffer when the
  -- value cannot be encoded.
  -- @param buf [List<String> buffer to write the error message to]
  -- @param val [Any value to encode]
  -- @return [Function encoding function, nil when the value cannot be encoded]
  function Encoder.get_encoder(buf, val)
    local encoder = get_encoder_impl(val)

    if encoder == nil then
      write_str(buf, 'unsupported type: ')
      write_str(buf, type(val))

      return nil
    end

    return encoder
  end

  local get_encoder = Encoder.get_encoder

  --- Writes a value with its encoding function.
  -- @param buf [List<String> buffer to write to]
  -- @param val [Any value to write]
  -- @return [Boolean true when the value cannot be encoded]
  function Encoder.write_value(buf, val)
    local encoder = get_encoder(buf, val)

    if encoder == nil then
      return true
    end

    return encoder(buf, val) == true
  end

  local write_value = Encoder.write_value

  --- Writes one byte.
  -- @alias [Encoder.write_u8]
  -- @param buf [List<String> buffer to write to]
  -- @param byte [Number byte from 0 to 255]
  function Encoder.write_byte(buf, byte)
    local buf_len = buf[0] + 1
    buf[0] = buf_len
    buf[buf_len] = chars[byte]
  end

  local write_byte = Encoder.write_byte

  Encoder.write_u8 = write_byte

  --- Writes an unsigned integer in two big-endian bytes.
  -- @param buf [List<String> buffer to write to]
  -- @param num [Number integer from 0 to 65 535]
  function Encoder.write_u16(buf, num)
    write_byte(buf, math_floor(num / 0x100))
    write_byte(buf, num % 0x100)
  end

  local write_u16 = Encoder.write_u16

  --- Writes an unsigned integer in four big-endian bytes.
  -- @param buf [List<String> buffer to write to]
  -- @param num [Number integer from 0 to 4 294 967 295]
  function Encoder.write_u32(buf, num)
    write_byte(buf, math_floor(num / 0x1000000) % 0x100)
    write_byte(buf, math_floor(num / 0x10000) % 0x100)
    write_byte(buf, math_floor(num / 0x100) % 0x100)
    write_byte(buf, num % 0x100)
  end

  local write_u32 = Encoder.write_u32

  --- Writes an unsigned integer in seven big-endian bytes, which hold every integer a double
  -- represents exactly.
  -- @param buf [List<String> buffer to write to]
  -- @param num [Number integer from 0 to 2^56 - 1]
  function Encoder.write_u53(buf, num)
    write_byte(buf, math_floor(num / 0x1000000000000) % 0x100)
    write_byte(buf, math_floor(num / 0x10000000000) % 0x100)
    write_byte(buf, math_floor(num / 0x100000000) % 0x100)
    write_byte(buf, math_floor(num / 0x1000000) % 0x100)
    write_byte(buf, math_floor(num / 0x10000) % 0x100)
    write_byte(buf, math_floor(num / 0x100) % 0x100)
    write_byte(buf, num % 0x100)
  end

  local write_u53 = Encoder.write_u53

  --- Writes a signed integer in one byte, in two's complement.
  -- @param buf [List<String> buffer to write to]
  -- @param num [Number integer from -128 to 127]
  function Encoder.write_i8(buf, num)
    write_byte(buf, num % 0x100)
  end

  --- Writes a signed integer in two big-endian bytes, in two's complement.
  -- @param buf [List<String> buffer to write to]
  -- @param num [Number integer from -32 768 to 32 767]
  function Encoder.write_i16(buf, num)
    write_u16(buf, num % 0x10000)
  end

  local write_i16 = Encoder.write_i16

  --- Writes a signed integer in four big-endian bytes, in two's complement.
  -- @param buf [List<String> buffer to write to]
  -- @param num [Number integer from -2 147 483 648 to 2 147 483 647]
  function Encoder.write_i32(buf, num)
    write_u32(buf, num % 0x100000000)
  end

  --- Writes a signed 53-bit integer in seven big-endian bytes, in two's complement.
  -- @param buf [List<String> buffer to write to]
  -- @param num [Number integer from -2^52 to 2^52 - 1]
  function Encoder.write_i53(buf, num)
    write_u53(buf, num % 0x20000000000000)
  end

  --- Writes the smallest of four consecutive type ids that fits an unsigned integer, followed by
  -- the integer: `tag` for 8 bits, `tag + 1` for 16, `tag + 2` for 32 and `tag + 3` for 53.
  -- @param buf [List<String> buffer to write to]
  -- @param tag [Number first of the four type ids]
  -- @param num [Number non-negative integer]
  function Encoder.write_varint(buf, tag, num)
    if num <= 255 then
      write_byte(buf, tag)
      write_byte(buf, num)
    elseif num <= 65_535 then
      write_byte(buf, tag + 1)
      write_u16(buf, num)
    elseif num <= 4_294_967_295 then
      write_byte(buf, tag + 2)
      write_u32(buf, num)
    else
      write_byte(buf, tag + 3)
      write_u53(buf, num)
    end
  end

  local write_varint = Encoder.write_varint

  --- Writes an IEEE 754 single-precision float in four big-endian bytes: the sign in bit 31, the
  -- biased exponent in bits 23 to 30 and the mantissa in bits 0 to 22. The number has to be one
  -- a float represents, such as a component of a vector or an angle, since others are not
  -- rounded correctly. Zero keeps its sign and NaN is written as 0x7FFFFFFF.
  -- @param buf [List<String> buffer to write to]
  -- @param num [Number float to write]
  -- @return [Number the four bytes as an unsigned integer]
  function Encoder.write_float(buf, num)
    local u32 = 0

    if num == 0 then
      if 1 / num < 0 then
        u32 = 0x80000000
      end

      write_u32(buf, u32)

      return u32
    elseif num != num then
      u32 = 0x7FFFFFFF
      write_u32(buf, u32)

      return u32
    end

    local sign = num < 0 ? 1 : 0
    num = sign == 1 and -num or num

    if num == INFINITY then
      u32 = (sign * (2 ^ 31)) + (0xFF * (2 ^ 23))
      write_u32(buf, u32)

      return u32
    end

    local mantissa, exponent = math_frexp(num)
    mantissa *= 2
    exponent -= 1

    local ieee_exponent = exponent + 127

    if ieee_exponent <= 0 then
      mantissa = math_ldexp(mantissa, ieee_exponent - 1)
      ieee_exponent = 0
    elseif ieee_exponent >= 255 then
      ieee_exponent = 255
      mantissa = 0
    end

    local mantissa_bits = math_floor(((mantissa - 1) * (2 ^ 23)) + 0.5)
    mantissa_bits %= 2 ^ 23

    u32 = (sign * (2 ^ 31)) + (ieee_exponent * (2 ^ 23)) + mantissa_bits
    write_u32(buf, u32)

    return u32
  end

  local write_float = Encoder.write_float

  --- Writes an IEEE 754 double-precision float in eight big-endian bytes: the sign in bit 63, the
  -- biased exponent in bits 52 to 62 and the mantissa in bits 0 to 51. Zero keeps its sign and
  -- NaN is written as 0x7FFFFFFF00000001.
  -- @param buf [List<String> buffer to write to]
  -- @param num [Number number to write]
  function Encoder.write_double(buf, num)
    local u32_1 = 0
    local u32_2 = 0

    if num == 0 then
      if 1 / num < 0 then
        u32_1 = 0x80000000
      end

      write_u32(buf, u32_1)
      write_u32(buf, u32_2)

      return
    elseif num != num then
      write_u32(buf, 0x7FFFFFFF)
      write_u32(buf, 1)

      return
    end

    local sign = num < 0 ? 1 : 0
    num = sign == 1 and -num or num

    if num == INFINITY then
      u32_1 = (sign * (2 ^ 31)) + (0x7FF * (2 ^ 20))
      write_u32(buf, u32_1)
      write_u32(buf, u32_2)

      return
    end

    local mantissa, exponent = math_frexp(num)
    local ieee_exponent = exponent + 1022

    if ieee_exponent > 0 then
      local mantissa_scaled = (mantissa * 2 - 1) * (2 ^ 52)
      local mantissa_upper = math_floor(mantissa_scaled / (2 ^ 32))

      u32_1 = (sign * (2 ^ 31)) + (ieee_exponent * (2 ^ 20)) + (mantissa_upper % (2 ^ 20))
      u32_2 = mantissa_scaled % (2 ^ 32)
    else
      local mantissa_scaled = mantissa * math_ldexp(1, 52 + ieee_exponent)
      local mantissa_upper = math_floor(mantissa_scaled / (2 ^ 32))

      u32_1 = (sign * (2 ^ 31)) + (mantissa_upper % (2 ^ 20))
      u32_2 = mantissa_scaled % (2 ^ 32)
    end

    write_u32(buf, u32_1)
    write_u32(buf, u32_2)
  end

  local write_double = Encoder.write_double

  --- Writes the first values of a list, nil ones included.
  -- @param buf [List<String> buffer to write to]
  -- @param arr [List<Any> list to write]
  -- @param size [Number amount of values to write]
  -- @return [Boolean true when a value cannot be encoded]
  function Encoder.write_array(buf, arr, size)
    for i = 1, size do
      if write_value(buf, arr[i]) then
        return true
      end
    end
  end

  local write_array = Encoder.write_array

  --- Writes every key and value of a table, each key followed by its value.
  -- @param buf [List<String> buffer to write to]
  -- @param tbl [Map table to write]
  -- @return [Boolean true when a key or a value cannot be encoded]
  function Encoder.write_table(buf, tbl)
    for key, val in pairs(tbl) do
      if write_value(buf, key) or write_value(buf, val) then
        return true
      end
    end
  end

  --- Returns the error message that a failed encoding function left in a buffer.
  -- @param buf [List<String> buffer that was written to]
  -- @return [String error message]
  function Encoder.read_error(buf)
    return table_concat(buf, nil, buf[0] - 1, buf[0])
  end

  local buffer = { [0] = 0 }

  --- Encodes a value into a string. The buffer it writes into is kept for the next call, and
  -- replaced by an empty one once it has grown past `max_cache_size` pieces.
  -- @alias [NFS.encode]
  -- @param val [Any value to encode]
  -- @param max_cache_size=2000 [Number largest amount of pieces the kept buffer may have]
  -- @return [String encoded data, or nil and String error message]
  function Encoder.encode(val, max_cache_size)
    max_cache_size = max_cache_size or 2000
    buffer[0] = 0

    if write_value(buffer, val) then
      return nil, Encoder.read_error(buffer)
    end

    local result = table_concat(buffer, nil, 1, buffer[0])

    if #buffer > max_cache_size then
      buffer = { [0] = 0 }
    end

    return result
  end

  encoders['nil'] = function(buf)
    write_byte(buf, NIL)
  end

  encoders.boolean = function(buf, val)
    write_byte(buf, val ? TRUE : FALSE)
  end

  encoders.float = function(buf, num)
    write_byte(buf, FLOAT)
    write_float(buf, num)
  end

  encoders.double = function(buf, num)
    write_byte(buf, DOUBLE)
    write_double(buf, num)
  end

  encoders.string = function(buf, str)
    local str_len = #str

    if str_len <= STRING_FIXED_MAX then
      write_byte(buf, STRING_FIXED_START + str_len)
    else
      write_varint(buf, STRING_U8, str_len)
    end

    if str_len > 0 then
      write_str(buf, str)
    end
  end

  --- Writes a list as an array of `size` values, nil ones included, or of its length without
  -- `size`. No value has the `array` type, so this encoder is only ever called directly.
  encoders.array = function(buf, arr, size)
    if size then
      if size < 0 then
        write_str(buf, 'array size cannot be negative: ')
        write_str(buf, size)

        return true
      end
    else
      size = #arr
    end

    write_byte(buf, ARRAY)

    if write_array(buf, arr, size) then
      return true
    end

    write_byte(buf, ENDING)
  end

  --- Writes a table as an array while its keys run 1, 2, 3 and so on. The first key that breaks
  -- the run turns it into a hash, or into an array followed by a hash, by rewriting the type id.
  encoders.table = function(buf, tbl)
    local tag_pos = buf[0] + 1
    buf[0] = tag_pos
    buf[tag_pos] = chars[ARRAY]

    local size = 0
    local is_pure_array = true

    for key, val in pairs(tbl) do
      if is_pure_array and key == size + 1 then
        size = key

        if write_value(buf, val) then
          return true
        end
      else
        if is_pure_array then
          is_pure_array = false

          if size == 0 then
            buf[tag_pos] = chars[TABLE]
          else
            buf[tag_pos] = chars[ARRAY_AND_TABLE]
            write_byte(buf, ENDING)
          end
        end

        if write_value(buf, key) or write_value(buf, val) then
          return true
        end
      end
    end

    write_byte(buf, ENDING)
  end

  --- Writes an integer in the smallest form that holds its magnitude, with the sign in the type
  -- id; the sign is taken from `1 / num`, so -0 stays negative. Numbers with a fraction, and
  -- numbers so large that subtracting 1 leaves them unchanged, are written as doubles.
  encoders.number = function(buf, num)
    if num % 1 != 0 or num - 1 == num then
      write_byte(buf, DOUBLE)
      write_double(buf, num)

      return
    end

    if 1 / num > 0 then
      if num <= POSITIVE_FIXED_MAX then
        write_byte(buf, POSITIVE_FIXED_START + num)
      else
        write_varint(buf, POSITIVE_U8, num)
      end
    else
      num = -num

      if num <= NEGATIVE_FIXED_MAX then
        write_byte(buf, NEGATIVE_FIXED_START + num)
      else
        write_varint(buf, NEGATIVE_U8, num)
      end
    end
  end

  const entity_index = FindMetaTable and FindMetaTable('Entity').EntIndex

  --- Writes an entity by its index, and NULL as `NULL_ENT_INDEX`. Weapons, vehicles, NPCs and
  -- next bots have types of their own and are written the same way.
  encoders.Entity = function(buf, ent)
    write_byte(buf, ENTITY)
    write_i16(buf, ent == NULL ? NULL_ENT_INDEX : entity_index(ent))
  end

  encoders.Weapon = encoders.Entity
  encoders.Vehicle = encoders.Entity
  encoders.NextBot = encoders.Entity
  encoders.NPC = encoders.Entity

  --- Writes a player by its index, which is 1 to 128 and fits in a byte.
  encoders.Player = function(buf, target)
    write_byte(buf, PLAYER)
    write_byte(buf, entity_index(target))
  end

  const vector_unpack = FindMetaTable and FindMetaTable('Vector').Unpack

  encoders.Vector = function(buf, vec)
    write_byte(buf, VECTOR)

    local x, y, z = vector_unpack(vec)
    write_float(buf, x)
    write_float(buf, y)
    write_float(buf, z)
  end

  const angle_unpack = FindMetaTable and FindMetaTable('Angle').Unpack

  encoders.Angle = function(buf, ang)
    write_byte(buf, ANGLE)

    local p, y, r = angle_unpack(ang)
    write_float(buf, p)
    write_float(buf, y)
    write_float(buf, r)
  end

  const matrix_to_table = FindMetaTable and FindMetaTable('VMatrix').ToTable

  encoders.VMatrix = function(buf, mat)
    write_byte(buf, MATRIX)

    local rows = matrix_to_table(mat)

    for i = 1, 4 do
      local row = rows[i]

      for j = 1, 4 do
        write_float(buf, row[j])
      end
    end
  end

  const color_meta = FindMetaTable and FindMetaTable('Color')

  if color_meta then
    encoders[color_meta] = function(buf, col)
      write_byte(buf, COLOR)
      write_byte(buf, math_floor(col.r))
      write_byte(buf, math_floor(col.g))
      write_byte(buf, math_floor(col.b))
      write_byte(buf, math_floor(col.a))
    end
  end
end

const decoders = {}

--- The decoding half of NFS. A context is a list of the read position, the bytes, their length
-- and the size past which reading fails. A decoding function reads from a context and returns
-- the value, or nil and an error message. `decoders` holds the decoding function of every type
-- id, and `decoders.string` reads a value that has to be a string.
const Decoder = {
  decoders = decoders
}

do
  const string_byte = string.byte
  const string_sub = string.sub

  const context = { 1, '', 0, INFINITY }

  --- Returns the type id at the read position without moving it.
  -- @param ctx [List context to read from]
  -- @return [Number type id, nil at the end of the bytes]
  function Decoder.peak_type(ctx)
    return string_byte(ctx[2], ctx[1])
  end

  local peak_type = Decoder.peak_type

  --- Returns the decoding function of the type id at the read position.
  -- @param ctx [List context to read from]
  -- @return [Function decoding function, or nil, String error message and Number type id]
  function Decoder.get_decoder(ctx)
    local type_id = peak_type(ctx)
    local decoder = decoders[type_id]

    if decoder == nil then
      return nil, 'unsupported type: ', type_id
    end

    return decoder
  end

  local get_decoder = Decoder.get_decoder

  --- Reads a value with the decoding function of its type id.
  -- @param ctx [List context to read from]
  -- @return [Any the value, or nil and String error message]
  function Decoder.read_value(ctx)
    local decoder, err, type_id = get_decoder(ctx)

    if err then
      return nil, type_id ? err..type_id : err
    end

    local val
    val, err = decoder(ctx)

    if err then
      return nil, err
    end

    return val
  end

  local read_value = Decoder.read_value

  --- Reads a number of bytes and moves the read position past them.
  -- @param ctx [List context to read from]
  -- @param size [Number amount of bytes to read]
  -- @return [Vararg one Number per byte, or nil and String error message]
  function Decoder.read_byte(ctx, size)
    local idx = ctx[1]
    local end_idx = idx + size - 1

    if end_idx > ctx[3] then
      return nil, 'bytes underflow'
    elseif end_idx > ctx[4] then
      return nil, 'bytes overflow'
    end

    ctx[1] = end_idx + 1

    return string_byte(ctx[2], idx, end_idx)
  end

  local read_byte = Decoder.read_byte

  --- Reads a string of a number of bytes and moves the read position past it.
  -- @param ctx [List context to read from]
  -- @param size [Number length of the string]
  -- @return [String the string, or nil and String error message]
  function Decoder.read_str(ctx, size)
    local idx = ctx[1]
    local end_idx = idx + size - 1

    if end_idx > ctx[3] then
      return nil, 'bytes underflow'
    elseif end_idx > ctx[4] then
      return nil, 'bytes overflow'
    end

    ctx[1] = end_idx + 1

    return string_sub(ctx[2], idx, end_idx)
  end

  local read_str = Decoder.read_str

  --- Reads an unsigned integer from one byte.
  -- @param ctx [List context to read from]
  -- @return [Number the integer, or nil and String error message]
  function Decoder.read_u8(ctx)
    local byte, err = read_byte(ctx, 1)

    if err then return nil, err end

    return byte
  end

  local read_u8 = Decoder.read_u8

  --- Reads an unsigned integer from two big-endian bytes.
  -- @param ctx [List context to read from]
  -- @return [Number the integer, or nil and String error message]
  function Decoder.read_u16(ctx)
    local b1, b2 = read_byte(ctx, 2)

    if b1 == nil then return nil, b2 end

    return b1 * 0x100 + b2
  end

  local read_u16 = Decoder.read_u16

  --- Reads an unsigned integer from four big-endian bytes.
  -- @param ctx [List context to read from]
  -- @return [Number the integer, or nil and String error message]
  function Decoder.read_u32(ctx)
    local b1, b2, b3, b4 = read_byte(ctx, 4)

    if b1 == nil then return nil, b2 end

    return b1 * 0x1000000 + b2 * 0x10000 + b3 * 0x100 + b4
  end

  local read_u32 = Decoder.read_u32

  --- Reads an unsigned integer from seven big-endian bytes.
  -- @param ctx [List context to read from]
  -- @return [Number the integer, or nil and String error message]
  function Decoder.read_u53(ctx)
    local b1, b2, b3, b4, b5, b6, b7 = read_byte(ctx, 7)

    if b1 == nil then return nil, b2 end

    return b1 * 0x1000000000000
        + b2 * 0x10000000000
        + b3 * 0x100000000
        + b4 * 0x1000000
        + b5 * 0x10000
        + b6 * 0x100
        + b7
  end

  local read_u53 = Decoder.read_u53

  --- Reads a signed integer from one byte in two's complement.
  -- @param ctx [List context to read from]
  -- @return [Number the integer, or nil and String error message]
  function Decoder.read_i8(ctx)
    local num, err = read_u8(ctx)

    if err then return nil, err end

    return num >= 0x80 ? num - 0x100 : num
  end

  --- Reads a signed integer from two big-endian bytes in two's complement.
  -- @param ctx [List context to read from]
  -- @return [Number the integer, or nil and String error message]
  function Decoder.read_i16(ctx)
    local num, err = read_u16(ctx)

    if err then return nil, err end

    return num >= 0x8000 ? num - 0x10000 : num
  end

  local read_i16 = Decoder.read_i16

  --- Reads a signed integer from four big-endian bytes in two's complement.
  -- @param ctx [List context to read from]
  -- @return [Number the integer, or nil and String error message]
  function Decoder.read_i32(ctx)
    local num, err = read_u32(ctx)

    if err then return nil, err end

    return num >= 0x80000000 ? num - 0x100000000 : num
  end

  --- Reads a signed 53-bit integer from seven big-endian bytes in two's complement.
  -- @param ctx [List context to read from]
  -- @return [Number the integer, or nil and String error message]
  function Decoder.read_i53(ctx)
    local num, err = read_u53(ctx)

    if err then return nil, err end

    return num >= 0x10000000000000 ? num - 0x20000000000000 : num
  end

  --- Reads an IEEE 754 single-precision float from four big-endian bytes.
  -- @param ctx [List context to read from]
  -- @return [Number the float, or nil and String error message]
  function Decoder.read_float(ctx)
    local u32, err = read_u32(ctx)

    if err then return nil, err end

    local sign = math_floor(u32 / (2 ^ 31)) % 2 == 1 ? -1 : 1
    local exponent_field = math_floor(u32 / (2 ^ 23)) % (2 ^ 8)
    local mantissa = u32 % (2 ^ 23)

    if exponent_field == 0xFF then
      return mantissa == 0 ? sign * INFINITY : 0 / 0
    end

    if exponent_field == 0 and mantissa == 0 then
      return sign * 0
    end

    local mantissa_scaled = mantissa / (2 ^ 23)

    if exponent_field == 0 then
      return sign * math_ldexp(mantissa_scaled, -126)
    end

    return sign * math_ldexp(mantissa_scaled + 1, exponent_field - 127)
  end

  local read_float = Decoder.read_float

  --- Reads an IEEE 754 double-precision float from eight big-endian bytes.
  -- @param ctx [List context to read from]
  -- @return [Number the number, or nil and String error message]
  function Decoder.read_double(ctx)
    local u32_1, u32_2, err

    u32_1, err = read_u32(ctx)

    if err then return nil, err end

    u32_2, err = read_u32(ctx)

    if err then return nil, err end

    local sign = math_floor(u32_1 / (2 ^ 31)) % 2 == 1 ? -1 : 1
    local exponent_field = math_floor(u32_1 / (2 ^ 20)) % (2 ^ 11)
    local mantissa_upper = u32_1 % (2 ^ 20)

    if exponent_field == 0x7FF then
      return mantissa_upper == 0 and u32_2 == 0 ? sign * INFINITY : 0 / 0
    end

    if exponent_field == 0 and mantissa_upper == 0 and u32_2 == 0 then
      return sign * 0
    end

    local mantissa_scaled = (mantissa_upper * (2 ^ 32) + u32_2) / (2 ^ 52)

    if exponent_field == 0 then
      return sign * math_ldexp(mantissa_scaled, -1022)
    end

    return sign * math_ldexp(mantissa_scaled + 1, exponent_field - 1023)
  end

  local read_double = Decoder.read_double

  --- Reads values into a list until the type id `till`, and moves the read position past it.
  -- @param ctx [List context to read from]
  -- @param till [Number type id that ends the list]
  -- @return [List<Any> the list, or nil and String error message, Number amount of values read]
  function Decoder.read_array(ctx, till)
    local arr = { nil, nil, nil, nil, nil, nil, nil, nil, nil, nil }
    local size = 0

    while peak_type(ctx) != till do
      local val, err = read_value(ctx)

      if err then return nil, err end

      size += 1
      arr[size] = val
    end

    ctx[1] += 1

    return arr, nil, size
  end

  local read_array = Decoder.read_array

  --- Reads keys and their values into a table until the type id `till`, and moves the read
  -- position past it. Keys that cannot index a table, nil and NaN, fail the read.
  -- @param ctx [List context to read from]
  -- @param tbl [Map table to read into]
  -- @param till [Number type id that ends the pairs]
  -- @return [Map the table, or nil and String error message]
  local function read_pairs(ctx, tbl, till)
    while peak_type(ctx) != till do
      local key, val, err

      key, err = read_value(ctx)

      if err then return nil, err end

      if key == nil or key != key then
        return nil, 'invalid table key'
      end

      val, err = read_value(ctx)

      if err then return nil, err end

      tbl[key] = val
    end

    ctx[1] += 1

    return tbl
  end

  --- Reads keys and their values into a table until the type id `till`, and moves the read
  -- position past it.
  -- @param ctx [List context to read from]
  -- @param till [Number type id that ends the table]
  -- @return [Map the table, or nil and String error message]
  function Decoder.read_table(ctx, till)
    return read_pairs(ctx, { nil, nil, nil, nil, nil, nil, nil, nil, nil, nil }, till)
  end

  local read_table = Decoder.read_table

  --- Points the context that `Decoder.decode` reads from at a string.
  -- @param bytes [String data to decode]
  -- @param max_size=math.huge [Number size past which reading fails]
  -- @return [List the context, or nil and String error message]
  function Decoder.setup_context(bytes, max_size)
    if !isstring(bytes) then
      return nil, 'bytes must be a string'
    end

    if max_size == nil then
      max_size = INFINITY
    elseif !isnumber(max_size) then
      return nil, 'max_size must be a number'
    elseif max_size < 1 then
      return nil, 'max_size must be greater than 0'
    end

    context[1] = 1
    context[2] = bytes
    context[3] = #bytes
    context[4] = max_size

    if context[3] < 1 then
      return nil, 'no bytes to decode'
    end

    return context
  end

  --- Decodes a string made by `Encoder.encode`.
  -- @alias [NFS.decode]
  -- @param bytes [String data to decode]
  -- @param max_size=math.huge [Number size past which decoding fails]
  -- @return [Any the value, or nil and String error message]
  function Decoder.decode(bytes, max_size)
    local _, err = Decoder.setup_context(bytes, max_size)

    if err then return nil, err end

    local val
    val, err = read_value(context)

    if err then return nil, err end

    return val
  end

  --- Returns a decoding function that skips the type id and returns what `read` reads.
  local function skip_type(read)
    return function(ctx)
      ctx[1] += 1

      return read(ctx)
    end
  end

  --- Returns a decoding function that skips the type id and negates the integer `read` reads.
  local function skip_type_negated(read)
    return function(ctx)
      ctx[1] += 1

      local num, err = read(ctx)

      if err then return nil, err end

      return -num
    end
  end

  --- Returns a decoding function that skips the type id and reads a string with the length
  -- `read_length` reads.
  local function skip_type_string(read_length)
    return function(ctx)
      ctx[1] += 1

      local str_len, err = read_length(ctx)

      if err then return nil, err end

      return read_str(ctx, str_len)
    end
  end

  --- Returns a decoding function that skips the type id and returns a constant.
  local function skip_type_constant(val)
    return function(ctx)
      ctx[1] += 1

      return val
    end
  end

  decoders[NIL] = skip_type_constant(nil)
  decoders[FALSE] = skip_type_constant(false)
  decoders[TRUE] = skip_type_constant(true)

  decoders[FLOAT] = skip_type(read_float)
  decoders[DOUBLE] = skip_type(read_double)

  const Entity = Entity

  decoders[ENTITY] = function(ctx)
    ctx[1] += 1

    local ent_index, err = read_i16(ctx)

    if err then return nil, err end

    return ent_index == NULL_ENT_INDEX ? NULL : Entity(ent_index)
  end

  decoders[PLAYER] = function(ctx)
    ctx[1] += 1

    local player_index, err = read_u8(ctx)

    if err then return nil, err end

    return Entity(player_index)
  end

  const Vector = Vector

  decoders[VECTOR] = function(ctx)
    ctx[1] += 1

    local x, y, z, err

    x, err = read_float(ctx)

    if err then return nil, err end

    y, err = read_float(ctx)

    if err then return nil, err end

    z, err = read_float(ctx)

    if err then return nil, err end

    return Vector(x, y, z)
  end

  const Angle = Angle

  decoders[ANGLE] = function(ctx)
    ctx[1] += 1

    local p, y, r, err

    p, err = read_float(ctx)

    if err then return nil, err end

    y, err = read_float(ctx)

    if err then return nil, err end

    r, err = read_float(ctx)

    if err then return nil, err end

    return Angle(p, y, r)
  end

  const Matrix = Matrix

  decoders[MATRIX] = function(ctx)
    ctx[1] += 1

    local rows = {}

    for i = 1, 4 do
      local row = {}

      for j = 1, 4 do
        local val, err = read_float(ctx)

        if err then return nil, err end

        row[j] = val
      end

      rows[i] = row
    end

    return Matrix(rows)
  end

  const Color = Color

  decoders[COLOR] = function(ctx)
    ctx[1] += 1

    local r, g, b, a = read_byte(ctx, 4)

    if r == nil then return nil, g end

    return Color(r, g, b, a)
  end

  decoders[POSITIVE_U8] = skip_type(read_u8)
  decoders[POSITIVE_U16] = skip_type(read_u16)
  decoders[POSITIVE_U32] = skip_type(read_u32)
  decoders[POSITIVE_U53] = skip_type(read_u53)

  decoders[NEGATIVE_U8] = skip_type_negated(read_u8)
  decoders[NEGATIVE_U16] = skip_type_negated(read_u16)
  decoders[NEGATIVE_U32] = skip_type_negated(read_u32)
  decoders[NEGATIVE_U53] = skip_type_negated(read_u53)

  decoders[STRING_U8] = skip_type_string(read_u8)
  decoders[STRING_U16] = skip_type_string(read_u16)
  decoders[STRING_U32] = skip_type_string(read_u32)

  decoders[ARRAY] = function(ctx)
    ctx[1] += 1

    local arr, err = read_array(ctx, ENDING)

    if err then return nil, err end

    return arr
  end

  decoders[TABLE] = function(ctx)
    ctx[1] += 1

    return read_table(ctx, ENDING)
  end

  decoders[ARRAY_AND_TABLE] = function(ctx)
    ctx[1] += 1

    local arr, err = read_array(ctx, ENDING)

    if err then return nil, err end

    return read_pairs(ctx, arr, ENDING)
  end

  decoders[STRING_FIXED_START] = function(ctx)
    local type_id, err = read_byte(ctx, 1)

    if err then return nil, err end

    return read_str(ctx, type_id - STRING_FIXED_START)
  end

  for i = 1, STRING_FIXED_MAX do
    decoders[STRING_FIXED_START + i] = decoders[STRING_FIXED_START]
  end

  decoders[POSITIVE_FIXED_START] = function(ctx)
    local type_id, err = read_byte(ctx, 1)

    if err then return nil, err end

    return type_id - POSITIVE_FIXED_START
  end

  for i = 1, POSITIVE_FIXED_MAX do
    decoders[POSITIVE_FIXED_START + i] = decoders[POSITIVE_FIXED_START]
  end

  decoders[NEGATIVE_FIXED_START] = function(ctx)
    local type_id, err = read_byte(ctx, 1)

    if err then return nil, err end

    return -(type_id - NEGATIVE_FIXED_START)
  end

  for i = 1, NEGATIVE_FIXED_MAX do
    decoders[NEGATIVE_FIXED_START + i] = decoders[NEGATIVE_FIXED_START]
  end

  decoders.string = function(ctx)
    if !STRING_TYPES[peak_type(ctx)] then
      return nil, 'expected string type'
    end

    return read_value(ctx)
  end
end

const NFS = {
  TYPES = TYPES,
  STRING_TYPES = STRING_TYPES,
  Encoder = Encoder,
  Decoder = Decoder,
  encode = Encoder.encode,
  decode = Decoder.decode,
  chars = chars,
  VERSION = '8.0.0'
}

do
  const string_byte = string.byte
  const string_char = string.char
  const string_format = string.format
  const string_gsub = string.gsub
  const tonumber = tonumber

  local function to_hex(char)
    return string_format('%02X', string_byte(char))
  end

  local function from_hex(pair)
    return string_char(tonumber(pair, 16))
  end

  local function hex_to_string(str)
    return (string_gsub(str, '..', from_hex))
  end

  --- Encodes a value into a string of hexadecimal digits, two per byte.
  -- @param val [Any value to encode]
  -- @return [String encoded data, or nil and String error message]
  function NFS.encode_to_hex(val)
    local encoded, err = Encoder.encode(val)

    if err then return nil, err end

    return (string_gsub(encoded, '.', to_hex))
  end

  --- Decodes a string of hexadecimal digits made by `NFS.encode_to_hex`.
  -- @param str [String encoded data]
  -- @return [Any the value, or nil and String error message]
  function NFS.decode_from_hex(str)
    local ok, unhexed = pcall(hex_to_string, str)

    if !ok then return nil, unhexed end

    local decoded, err = Decoder.decode(unhexed)

    if err then return nil, err end

    return decoded
  end
end

--- Creates an empty buffer for the writing functions of `NFS.Encoder`.
-- @return [List<String> the buffer]
function NFS.new_buffer()
  return { [0] = 0 }
end

--- Concatenates the pieces of a buffer.
-- @param buf [List<String> buffer that was written to]
-- @return [String encoded data]
function NFS.end_buffer(buf)
  return table_concat(buf, nil, 1, buf[0])
end

--- Empties a buffer for reuse.
-- @param buf [List<String> buffer to empty]
function NFS.reset_buffer(buf)
  buf[0] = 0
end

--- Replaces the function the encoder names the type of a value with, such as with one the JIT
-- compiler compiles where the engine's own does not.
-- @param type_function [Function returns the type name of the value it is given]
function NFS.set_type_function(type_function)
  type = type_function
end

local next_custom_type = CUSTOM_START

--- Adds a custom type under the next free custom type id and returns the id. `encoder(buf, val)`
-- writes the id with `NFS.Encoder.write_byte`, then the value, and returns true when it fails;
-- `decoder(ctx)` skips the id, reads the value and returns it, or nil and an error message.
-- Adding a type that has an encoder already prints a warning and replaces the encoder.
-- ```
-- local Tag = {}
-- local tag_type
--
-- tag_type = NFS.add_custom_type(Tag, function(buf, tag)
--   NFS.Encoder.write_byte(buf, tag_type)
--   NFS.Encoder.encoders.string(buf, tag.name)
-- end, function(ctx)
--   ctx[1] += 1
--
--   local name, err = NFS.Decoder.decoders.string(ctx)
--
--   if err then return nil, err end
--
--   return setmetatable({ name = name }, Tag)
-- end)
-- ```
-- @param type_key [String/Map type name or metatable of the values the encoder is for]
-- @param encoder [Function writes a value into a buffer]
-- @param decoder [Function reads a value from a context]
-- @return [Number type id of the custom type]
function NFS.add_custom_type(type_key, encoder, decoder)
  if next_custom_type > CUSTOM_START + CUSTOM_MAX then
    error('cannot add more custom types', 2)
  end

  if encoders[type_key] then
    ErrorNoHaltWithStack('type already exists: `'..tostring(type_key)..'`')
  end

  local type_id = next_custom_type

  encoders[type_key] = encoder
  decoders[type_id] = decoder
  next_custom_type += 1

  return type_id
end

--- Sets the encoder and the decoder of a custom type under a type id of the caller's choice, for
-- ids that have to stay the same whatever order types are added in. Taking a type that has an
-- encoder or an id that has a decoder already prints a warning and replaces them.
-- @param type_id [Number type id of the custom type]
-- @param type_key [String/Map type name or metatable of the values the encoder is for]
-- @param encoder [Function writes a value into a buffer]
-- @param decoder [Function reads a value from a context]
function NFS.set_custom_type_with_id(type_id, type_key, encoder, decoder)
  if encoders[type_key] or decoders[type_id] then
    ErrorNoHaltWithStack('type already exists: `'..tostring(type_key)..'`')
  end

  encoders[type_key] = encoder
  decoders[type_id] = decoder
end

return NFS
