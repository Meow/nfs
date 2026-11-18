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
-- Failures are returned as nil and an error message. The encoder writes pieces into a list that
-- is concatenated once at the end, and the decoder walks the string with a position that it
-- passes along. Both tell values apart with comparisons, metatables and the type id instead of
-- calling the engine's `type`, and neither concatenates strings, creates closures or calls
-- `math.frexp` and `math.ldexp` on the way of a value. That leaves the JIT compilers of LuaJIT
-- 2.0 and 2.1 nothing they do not compile but the calls into the engine and, before the 2.1
-- that compiles them, the `pairs` loops of the encoder.
-- ```
-- local data = NFS.encode({ 1, 2, 3, name = 'value' })
-- local value, err = NFS.decode(data)
-- ```
-- @module [NFS]

const pairs = pairs
const getmetatable = getmetatable
const tostring = tostring
const tonumber = tonumber
const pcall = pcall
const rawget = rawget
const table_concat = table.concat
const math_floor = math.floor
const math_log = math.log
const math_max = math.max
const math_min = math.min
const string_byte = string.byte
const string_sub = string.sub
const INFINITY = math.huge
const NAN = 0 / 0

--- Negative zero, which the decoder returns as a constant: the JIT compilers of LuaJIT 2.0 and
-- 2.1.0-beta3 turn the negation of a difference into a difference that is positive zero.
const NEGATIVE_ZERO = -1 / INFINITY

--- The metatable of strings, which tells a string apart without a call of `type` or `isstring`:
-- those are Lua functions of the engine with traces of their own, and LuaJIT ends the trace of
-- the caller at a call of such a function.
const STRING_META = getmetatable('')

--- The function the encoder names the type of a value with when the value is not nil, a boolean,
-- a number or a string and its metatable has no encoder. `NFS.set_type_function` replaces it.
local type = type

--- Whether `type` is the function the library was loaded with, for which every table is a
-- table.
local engine_type = true

--- The metatable the encoder knows a string by. A custom type for strings replaces it by a
-- table that is no metatable, which leaves strings to the encoder of their type name.
local string_meta = STRING_META

--- Whether the encoder writes nil, booleans and numbers in place. A custom type for one of them
-- turns it off, which leaves them to the encoders of their type names.
local inline_primitives = true

--- One-character strings of every byte, indexed by the byte. The encoder looks them up instead
-- of calling `string.char`, which the JIT compiler of LuaJIT 2.0 does not compile.
const chars = {}

for i = 0, 255 do
  chars[i] = string.char(i)
end

--- Index of 2^0 in `pow2`.
const POW2_BIAS = 1024

--- Powers of two: `pow2[POW2_BIAS + e]` is 2^e for every e from -1023 to 1024, where it is
-- infinity. They are made by doubling and halving 1, which is exact on every platform, and
-- scale the mantissas of floats and doubles. The engine has the processor flush subnormal
-- numbers to zero, so the one subnormal power, 2^-1023, is 0 in the game; it only ever stands
-- in a comparison.
const pow2 = {}

for i = 1, POW2_BIAS + 1024 do
  pow2[i] = 0
end

do
  local power = 1

  for i = POW2_BIAS, POW2_BIAS + 1024 do
    pow2[i] = power
    power *= 2
  end

  power = 1

  for i = POW2_BIAS - 1, 1, -1 do
    power /= 2
    pow2[i] = power
  end
end

--- Ranges of type ids by type name: `start` is the first id of a range and `max` the highest
-- offset from it. Ids are handed out in the order of the `new_type` calls below, so data only
-- decodes with the version of NFS that encoded it. The decoder tells the three leading ranges
-- and the table ids after them apart by comparing ids, so they stay first and in this order.
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

const POSITIVE_FIXED_START, POSITIVE_FIXED_MAX = new_type('positive_fixed', 101)
const STRING_FIXED_START, STRING_FIXED_MAX     = new_type('string_fixed', 56)
const NEGATIVE_FIXED_START, NEGATIVE_FIXED_MAX = new_type('negative_fixed', 55)

const ARRAY                                    = new_type('array')
const TABLE                                    = new_type('table')
const ARRAY_AND_TABLE                          = new_type('array_and_table')
const ENDING                                   = new_type('ending')

const NIL                                      = new_type('nil')
const FALSE                                    = new_type('false')
const TRUE                                     = new_type('true')

const POSITIVE_U8                              = new_type('positive_u8')
const POSITIVE_U16                             = new_type('positive_u16')
const POSITIVE_U32                             = new_type('positive_u32')
const POSITIVE_U53                             = new_type('positive_u53')

const NEGATIVE_U8                              = new_type('negative_u8')
const NEGATIVE_U16                             = new_type('negative_u16')
const NEGATIVE_U32                             = new_type('negative_u32')
const NEGATIVE_U53                             = new_type('negative_u53')

const STRING_U8                                = new_type('string_u8')
const STRING_U16                               = new_type('string_u16')
const STRING_U32                               = new_type('string_u32')

const FLOAT                                    = new_type('float')
const DOUBLE                                   = new_type('double')

const ENTITY                                   = new_type('entity')
const PLAYER                                   = new_type('player')
const VECTOR                                   = new_type('vector')
const ANGLE                                    = new_type('angle')
const MATRIX                                   = new_type('matrix')
const COLOR                                    = new_type('color')

const CUSTOM_START, CUSTOM_MAX                 = new_type('custom', 18)

const POSITIVE_FIXED_END = POSITIVE_FIXED_START + POSITIVE_FIXED_MAX
const STRING_FIXED_END = STRING_FIXED_START + STRING_FIXED_MAX
const NEGATIVE_FIXED_END = NEGATIVE_FIXED_START + NEGATIVE_FIXED_MAX

--- Index written for NULL, the lowest 16-bit integer: NULL and the world both have index 0, and
-- entities that are not networked have index -1.
const NULL_ENT_INDEX = -0x8000

--- Integers from this magnitude on are written as doubles: seven bytes hold the ones below it.
const INTEGER_LIMIT = 0x100000000000000

--- Set of the type ids of strings.
const STRING_TYPES = {
  [STRING_U8] = true,
  [STRING_U16] = true,
  [STRING_U32] = true
}

for i = 0, STRING_FIXED_MAX do
  STRING_TYPES[STRING_FIXED_START + i] = true
end

--- Metatables of the engine types by type name, for the types whose encoder is found by the
-- metatable of the value.
const engine_metas = {}

const encoders = {}

--- The encoding half of NFS. A buffer is a list of strings with its length at index 0, and an
-- encoding function writes into it and returns true when it fails, leaving the error message in
-- the last two pieces of the buffer. `encoders` holds the encoding function of every metatable
-- and type name, and `ENDING` is the id that closes arrays and tables, which custom types may
-- use to close lists of their own.
--
-- `Encoder.encode` itself passes the length of the buffer from one writing function to the next
-- instead of keeping it at index 0, and only stores it there around the encoders of engine and
-- custom types. It writes nil, booleans, numbers, strings and tables in place, so the entries
-- of `encoders` for them only serve callers of their own, unless a custom type replaces one.
const Encoder = {
  encoders = encoders,
  ENDING = ENDING
}

do
  const INVERSE_LN2 = 1 / math_log(2)
  const DOUBLE_MIN_NORMAL = pow2[POW2_BIAS - 1022]
  const FLOAT_MIN_NORMAL = pow2[POW2_BIAS - 126]
  const FLOAT_OVERFLOW = pow2[POW2_BIAS + 128]
  const FLOAT_SUBNORMAL_SCALE = pow2[POW2_BIAS + 149]
  const HALF_SUBNORMAL_SCALE = pow2[POW2_BIAS + 537]

  const NIL_PIECE = chars[NIL]
  const FALSE_PIECE = chars[FALSE]
  const TRUE_PIECE = chars[TRUE]
  const POSITIVE_ZERO_PIECE = chars[POSITIVE_FIXED_START]
  const NEGATIVE_ZERO_PIECE = chars[NEGATIVE_FIXED_START]
  const FLOAT_PIECE = chars[FLOAT]
  const DOUBLE_PIECE = chars[DOUBLE]
  const ARRAY_PIECE = chars[ARRAY]
  const TABLE_PIECE = chars[TABLE]
  const ARRAY_AND_TABLE_PIECE = chars[ARRAY_AND_TABLE]
  const ENDING_PIECE = chars[ENDING]

  --- Returns the exponent of the highest bit of a positive, finite number: the e for which
  -- 2^e <= num < 2^(e + 1). The logarithm estimates it and the powers around it correct it.
  local function binary_exponent(num)
    local exponent = math_floor(math_log(num) * INVERSE_LN2)

    if num < pow2[POW2_BIAS + exponent] then
      return exponent - 1
    elseif num >= pow2[POW2_BIAS + exponent + 1] then
      return exponent + 1
    end

    return exponent
  end

  --- Returns the bits of the IEEE 754 single-precision float nearest to a number: the sign in
  -- bit 31, the biased exponent in bits 23 to 30 and the mantissa in bits 0 to 22. Zero keeps its
  -- sign and NaN is 0x7FC00000.
  -- @param num [Number number to convert]
  -- @return [Number the bits as an unsigned integer]
  local function float_bits(num)
    local sign = 0

    if num < 0 then
      sign = 0x80000000
      num = -num
    elseif num == 0 then
      if 1 / num < 0 then
        return 0x80000000
      end

      return 0
    elseif num != num then
      return 0x7FC00000
    end

    if num >= FLOAT_OVERFLOW then
      return sign + 0x7F800000
    elseif num < FLOAT_MIN_NORMAL then
      return sign + math_floor(num * FLOAT_SUBNORMAL_SCALE + 0.5)
    end

    local exponent = binary_exponent(num)

    return sign + (exponent + 127) * 0x800000
        + math_floor((num / pow2[POW2_BIAS + exponent] - 1) * 0x800000 + 0.5)
  end

  --- Splits an unsigned integer below 2^56 into its bits from 32 up and its bits 0 to 31. The low
  -- word is scaled back from the fraction instead of subtracted from the integer: the JIT
  -- compiler moves the conversion of a bit operation into the operands of a subtraction, and
  -- that conversion is only exact below 2^51.
  -- @return [Number bits from 32 up, Number bits 0 to 31]
  local function split_words(num)
    local scaled = num / 0x100000000
    local upper = math_floor(scaled)

    return upper, (scaled - upper) * 0x100000000
  end

  --- Returns the bits of a number as an IEEE 754 double: the sign in bit 63, the biased exponent
  -- in bits 52 to 62 and the mantissa in bits 0 to 51. Zero keeps its sign and NaN is
  -- 0x7FF8000000000000.
  -- @param num [Number number to convert]
  -- @return [Number bits 32 to 63 as an unsigned integer, Number bits 0 to 31]
  local function double_bits(num)
    local sign = 0

    if num < 0 then
      sign = 0x80000000
      num = -num
    elseif num == 0 then
      if 1 / num < 0 then
        return 0x80000000, 0
      end

      return 0, 0
    elseif num != num then
      return 0x7FF80000, 0
    end

    if num == INFINITY then
      return sign + 0x7FF00000, 0
    end

    local mantissa

    if num < DOUBLE_MIN_NORMAL then
      mantissa = num * HALF_SUBNORMAL_SCALE * HALF_SUBNORMAL_SCALE
    else
      local exponent = binary_exponent(num)

      sign += (exponent + 1023) * 0x100000
      mantissa = (num / pow2[POW2_BIAS + exponent] - 1) * 0x10000000000000
    end

    local upper, lower = split_words(mantissa)

    return sign + upper, lower
  end

  --- Writes an unsigned integer below 2^32 as four big-endian pieces after the first `n` pieces
  -- of a buffer.
  -- @return [Number amount of pieces in the buffer]
  local function put_u32(buf, n, num)
    buf[n + 1] = chars[num >> 24]
    buf[n + 2] = chars[num >> 16 & 0xFF]
    buf[n + 3] = chars[num >> 8 & 0xFF]
    buf[n + 4] = chars[num & 0xFF]

    return n + 4
  end

  --- Writes an unsigned integer below 2^56 as seven big-endian pieces.
  -- @return [Number amount of pieces in the buffer]
  local function put_u53(buf, n, num)
    local upper, lower = split_words(num)

    buf[n + 1] = chars[upper >> 16]
    buf[n + 2] = chars[upper >> 8 & 0xFF]
    buf[n + 3] = chars[upper & 0xFF]

    return put_u32(buf, n + 3, lower)
  end

  --- Writes the smallest of four consecutive type ids that fits an unsigned integer, followed by
  -- the integer.
  -- @return [Number amount of pieces in the buffer]
  local function put_varint(buf, n, tag, num)
    if num <= 0xFF then
      buf[n + 1] = chars[tag]
      buf[n + 2] = chars[num]

      return n + 2
    elseif num <= 0xFFFF then
      buf[n + 1] = chars[tag + 1]
      buf[n + 2] = chars[num >> 8]
      buf[n + 3] = chars[num & 0xFF]

      return n + 3
    elseif num <= 0xFFFFFFFF then
      buf[n + 1] = chars[tag + 2]

      return put_u32(buf, n + 1, num)
    end

    buf[n + 1] = chars[tag + 3]

    return put_u53(buf, n + 1, num)
  end

  --- Writes a number: an integer in the smallest form that holds its magnitude, with the sign in
  -- the type id, and anything else as a double. Zero takes its sign from `1 / num`, so -0 stays
  -- negative.
  -- @return [Number amount of pieces in the buffer]
  local function put_number(buf, n, num)
    if num % 1 == 0 then
      if num > 0 then
        if num <= POSITIVE_FIXED_MAX then
          buf[n + 1] = chars[POSITIVE_FIXED_START + num]

          return n + 1
        elseif num < INTEGER_LIMIT then
          return put_varint(buf, n, POSITIVE_U8, num)
        end
      elseif num < 0 then
        if num >= -NEGATIVE_FIXED_MAX then
          buf[n + 1] = chars[NEGATIVE_FIXED_START - num]

          return n + 1
        elseif num > -INTEGER_LIMIT then
          return put_varint(buf, n, NEGATIVE_U8, -num)
        end
      else
        if 1 / num < 0 then
          buf[n + 1] = NEGATIVE_ZERO_PIECE
        else
          buf[n + 1] = POSITIVE_ZERO_PIECE
        end

        return n + 1
      end
    end

    local upper, lower = double_bits(num)

    buf[n + 1] = DOUBLE_PIECE

    return put_u32(buf, put_u32(buf, n + 1, upper), lower)
  end

  --- Writes a string: its length, in the type id when that is short, then its bytes.
  -- @return [Number amount of pieces in the buffer]
  local function put_string(buf, n, str)
    local str_len = #str

    if str_len <= STRING_FIXED_MAX then
      buf[n + 1] = chars[STRING_FIXED_START + str_len]
      buf[n + 2] = str

      return n + 2
    end

    n = put_varint(buf, n, STRING_U8, str_len)
    buf[n + 1] = str

    return n + 1
  end

  local put_other

  --- Writes a value after the first `n` pieces of a buffer. `tonumber` returns a number and nil
  -- as they are and nothing else, which tells them apart from every other value. Strings are
  -- told apart before it, since the JIT compiler does not compile `tonumber` for a string that
  -- is not a number.
  -- @param buf [List<String> buffer to write to]
  -- @param n [Number amount of pieces in the buffer]
  -- @param val [Any value to write]
  -- @return [Number amount of pieces in the buffer; nil when the value cannot be encoded, with
  --   the error message in the last two pieces and the amount of pieces at index 0]
  local function put_value(buf, n, val)
    local meta = getmetatable(val)

    if meta == string_meta then
      return put_string(buf, n, val)
    elseif inline_primitives then
      if tonumber(val) == val then
        if val != nil then
          return put_number(buf, n, val)
        end

        buf[n + 1] = NIL_PIECE

        return n + 1
      elseif meta == nil then
        if val == true then
          buf[n + 1] = TRUE_PIECE

          return n + 1
        elseif val == false then
          buf[n + 1] = FALSE_PIECE

          return n + 1
        end
      end
    end

    return put_other(buf, n, val)
  end

  --- Writes a table as an array while its keys run 1, 2, 3 and so on. The first key that breaks
  -- the run turns it into a hash, or into an array followed by a hash, by rewriting the type id.
  -- A key that is a short string is written in place, which leaves one call of `put_value` to a
  -- turn of the loop.
  -- @return [Number amount of pieces in the buffer, nil when a key or a value cannot be encoded]
  local function put_table(buf, n, tbl)
    local tag_pos = n + 1
    local size = 0
    local is_array = true

    buf[tag_pos] = ARRAY_PIECE
    n = tag_pos

    for key, val in pairs(tbl) do
      if is_array and key == size + 1 then
        size = key
        n = put_value(buf, n, val)
      else
        if is_array then
          is_array = false

          if size == 0 then
            buf[tag_pos] = TABLE_PIECE
          else
            buf[tag_pos] = ARRAY_AND_TABLE_PIECE
            n += 1
            buf[n] = ENDING_PIECE
          end
        end

        if getmetatable(key) == string_meta and #key <= STRING_FIXED_MAX then
          buf[n + 1] = chars[STRING_FIXED_START + #key]
          buf[n + 2] = key
          n = put_value(buf, n + 2, val)
        else
          n = put_value(buf, n, key)

          if n then
            n = put_value(buf, n, val)
          end
        end
      end

      if !n then return end
    end

    buf[n + 1] = ENDING_PIECE

    return n + 1
  end

  encoders.table = function(buf, tbl)
    local n = put_table(buf, buf[0], tbl)

    if !n then
      return true
    end

    buf[0] = n
  end

  const encode_table = encoders.table

  --- Writes a value with the encoding function of its metatable or, without one, of its type.
  -- While `type` is the engine's own, for which every table is a table, a table is known by
  -- `rawget` taking it: the engine's `type` is a Lua function with a trace of its own, and a
  -- call of it would end the trace of the table that is being written.
  -- @param buf [List<String> buffer to write to]
  -- @param n [Number amount of pieces in the buffer]
  -- @param val [Any value to write]
  -- @return [Number amount of pieces in the buffer, nil when the value cannot be encoded]
  function put_other(buf, n, val)
    local meta = getmetatable(val)
    local encoder

    if meta != nil then
      encoder = encoders[meta]
    end

    if encoder == nil then
      if engine_type and pcall(rawget, val, 1) and encoders.table == encode_table then
        return put_table(buf, n, val)
      end

      local kind = type(val)

      encoder = encoders[kind]

      if encoder == encode_table then
        return put_table(buf, n, val)
      elseif encoder == nil then
        buf[n + 1] = 'unsupported type: '
        buf[n + 2] = kind
        buf[0] = n + 2

        return
      end
    end

    buf[0] = n

    if encoder(buf, val) == true then return end

    return buf[0]
  end

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

  --- Writes a value.
  -- @param buf [List<String> buffer to write to]
  -- @param val [Any value to write]
  -- @return [Boolean true when the value cannot be encoded]
  function Encoder.write_value(buf, val)
    local n = put_value(buf, buf[0], val)

    if !n then
      return true
    end

    buf[0] = n

    return false
  end

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
    local n = buf[0]

    buf[n + 1] = chars[num >> 8]
    buf[n + 2] = chars[num & 0xFF]
    buf[0] = n + 2
  end

  local write_u16 = Encoder.write_u16

  --- Writes an unsigned integer in four big-endian bytes.
  -- @param buf [List<String> buffer to write to]
  -- @param num [Number integer from 0 to 4 294 967 295]
  function Encoder.write_u32(buf, num)
    buf[0] = put_u32(buf, buf[0], num)
  end

  local write_u32 = Encoder.write_u32

  --- Writes an unsigned integer in seven big-endian bytes, which hold every integer a double
  -- represents exactly.
  -- @param buf [List<String> buffer to write to]
  -- @param num [Number integer from 0 to 2^56 - 1]
  function Encoder.write_u53(buf, num)
    buf[0] = put_u53(buf, buf[0], num)
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
    buf[0] = put_varint(buf, buf[0], tag, num)
  end

  --- Writes an IEEE 754 single-precision float in four big-endian bytes: the sign in bit 31, the
  -- biased exponent in bits 23 to 30 and the mantissa in bits 0 to 22. A number that a float does
  -- not represent, unlike the components of vectors and angles, is rounded to the nearest float.
  -- Zero keeps its sign and NaN is written as 0x7FC00000.
  -- @param buf [List<String> buffer to write to]
  -- @param num [Number float to write]
  -- @return [Number the four bytes as an unsigned integer]
  function Encoder.write_float(buf, num)
    local u32 = float_bits(num)

    buf[0] = put_u32(buf, buf[0], u32)

    return u32
  end

  --- Writes an IEEE 754 double-precision float in eight big-endian bytes: the sign in bit 63, the
  -- biased exponent in bits 52 to 62 and the mantissa in bits 0 to 51. Zero keeps its sign and
  -- NaN is written as 0x7FF8000000000000.
  -- @param buf [List<String> buffer to write to]
  -- @param num [Number number to write]
  function Encoder.write_double(buf, num)
    local upper, lower = double_bits(num)

    buf[0] = put_u32(buf, put_u32(buf, buf[0], upper), lower)
  end

  --- Writes the first values of a list, nil ones included.
  -- @param buf [List<String> buffer to write to]
  -- @param arr [List<Any> list to write]
  -- @param size [Number amount of values to write]
  -- @return [Boolean true when a value cannot be encoded]
  function Encoder.write_array(buf, arr, size)
    local n = buf[0]

    for i = 1, size do
      n = put_value(buf, n, arr[i])

      if !n then
        return true
      end
    end

    buf[0] = n
  end

  local write_array = Encoder.write_array

  --- Writes every key and value of a table, each key followed by its value.
  -- @param buf [List<String> buffer to write to]
  -- @param tbl [Map table to write]
  -- @return [Boolean true when a key or a value cannot be encoded]
  function Encoder.write_table(buf, tbl)
    local n = buf[0]

    for key, val in pairs(tbl) do
      n = put_value(buf, n, key)

      if n then
        n = put_value(buf, n, val)
      end

      if !n then
        return true
      end
    end

    buf[0] = n
  end

  --- Returns the error message that a failed encoding function left in a buffer.
  -- @param buf [List<String> buffer that was written to]
  -- @return [String error message]
  function Encoder.read_error(buf)
    return table_concat(buf, nil, buf[0] - 1, buf[0])
  end

  local read_error = Encoder.read_error

  --- The buffer `Encoder.encode` writes into, nil while an encode is using it.
  local cached_buffer

  --- Encodes a value into a string. The buffer it writes into is kept for the next call, unless
  -- the value took more than `max_cache_size` pieces.
  -- @alias [NFS.encode]
  -- @param val [Any value to encode]
  -- @param max_cache_size=65536 [Number largest amount of pieces the kept buffer may hold]
  -- @return [String encoded data, or nil and String error message]
  function Encoder.encode(val, max_cache_size)
    local buf = cached_buffer or { [0] = 0 }

    cached_buffer = nil

    local n = put_value(buf, 0, val)

    if !n then
      local err = read_error(buf)

      cached_buffer = buf

      return nil, err
    end

    local result = table_concat(buf, nil, 1, n)

    if n <= (max_cache_size or 65_536) then
      cached_buffer = buf
    end

    return result
  end

  encoders['nil'] = function(buf)
    write_byte(buf, NIL)
  end

  encoders.boolean = function(buf, val)
    if val then
      write_byte(buf, TRUE)
    else
      write_byte(buf, FALSE)
    end
  end

  encoders.float = function(buf, num)
    local n = buf[0] + 1

    buf[n] = FLOAT_PIECE
    buf[0] = put_u32(buf, n, float_bits(num))
  end

  encoders.double = function(buf, num)
    local upper, lower = double_bits(num)
    local n = buf[0] + 1

    buf[n] = DOUBLE_PIECE
    buf[0] = put_u32(buf, put_u32(buf, n, upper), lower)
  end

  encoders.string = function(buf, str)
    buf[0] = put_string(buf, buf[0], str)
  end

  encoders.number = function(buf, num)
    buf[0] = put_number(buf, buf[0], num)
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

  --- Registers the encoder of an engine type under its type name and, in the game, under its
  -- metatable, where `Encoder.encode` finds it without asking for the type of the value.
  local function add_engine_type(name, encoder)
    local meta = FindMetaTable and FindMetaTable(name)

    encoders[name] = encoder

    if meta then
      engine_metas[name] = meta
      encoders[meta] = encoder
    end
  end

  const entity_index = FindMetaTable and FindMetaTable('Entity').EntIndex
  const ENTITY_PIECE = chars[ENTITY]

  --- Writes an entity by its index, and NULL as `NULL_ENT_INDEX`. An entity that is not valid has
  -- index 0 like the world, so only that index is compared with NULL. Weapons, vehicles, NPCs
  -- and next bots have types of their own and are written the same way.
  local function encode_entity(buf, ent)
    local index = entity_index(ent)

    if index == 0 and ent == NULL then
      index = NULL_ENT_INDEX
    end

    local n = buf[0]

    buf[n + 1] = ENTITY_PIECE
    buf[n + 2] = chars[index >> 8 & 0xFF]
    buf[n + 3] = chars[index & 0xFF]
    buf[0] = n + 3
  end

  add_engine_type('Entity', encode_entity)
  add_engine_type('Weapon', encode_entity)
  add_engine_type('Vehicle', encode_entity)
  add_engine_type('NextBot', encode_entity)
  add_engine_type('NPC', encode_entity)

  const PLAYER_PIECE = chars[PLAYER]

  --- Writes a player by its index, which is 1 to 128 and fits in a byte. A player that has left
  -- has index 0.
  add_engine_type('Player', function(buf, target)
    local n = buf[0]

    buf[n + 1] = PLAYER_PIECE
    buf[n + 2] = chars[entity_index(target)]
    buf[0] = n + 2
  end)

  --- Returns an encoder that writes a type id and the three numbers `components` returns as
  -- floats.
  local function triple_encoder(type_id, components)
    const piece = chars[type_id]

    return function(buf, val)
      local x, y, z = components(val)
      local n = buf[0] + 1

      buf[n] = piece
      n = put_u32(buf, n, float_bits(x))
      n = put_u32(buf, n, float_bits(y))
      buf[0] = put_u32(buf, n, float_bits(z))
    end
  end

  add_engine_type('Vector', triple_encoder(VECTOR, FindMetaTable and FindMetaTable('Vector').Unpack))
  add_engine_type('Angle', triple_encoder(ANGLE, FindMetaTable and FindMetaTable('Angle').Unpack))

  const matrix_to_table = FindMetaTable and FindMetaTable('VMatrix').ToTable
  const MATRIX_PIECE = chars[MATRIX]

  add_engine_type('VMatrix', function(buf, mat)
    local rows = matrix_to_table(mat)
    local n = buf[0] + 1

    buf[n] = MATRIX_PIECE

    for i = 1, 4 do
      local row = rows[i]

      for j = 1, 4 do
        n = put_u32(buf, n, float_bits(row[j]))
      end
    end

    buf[0] = n
  end)

  const color_meta = FindMetaTable and FindMetaTable('Color')
  const COLOR_PIECE = chars[COLOR]

  --- Returns the piece of a color channel that is not an integer from 0 to 255: it is floored
  -- and kept within that range.
  local function clamped_piece(num)
    local byte = math_floor(num)

    if byte > 255 then
      return chars[255]
    end

    return chars[byte] or chars[0]
  end

  if color_meta then
    encoders[color_meta] = function(buf, col)
      local n = buf[0]
      local r, g, b, a = col.r, col.g, col.b, col.a

      buf[n + 1] = COLOR_PIECE
      buf[n + 2] = chars[r] or clamped_piece(r)
      buf[n + 3] = chars[g] or clamped_piece(g)
      buf[n + 4] = chars[b] or clamped_piece(b)
      buf[n + 5] = chars[a] or clamped_piece(a)
      buf[0] = n + 5
    end
  end
end

const decoders = {}

--- Functions that read the value of a type id that is not a small integer, a short string or
-- part of a table, indexed by the id; false for every other id. They take the bytes, the
-- position of the id and the last position they may read, and return the value and the position
-- after it, or two nils after leaving the error message for `Decoder.decode`.
const readers = {}

for i = 0, 255 do
  readers[i] = false
end

--- The decoding half of NFS. A context is a list of the read position, the bytes, their length
-- and the size past which reading fails. A decoding function reads from a context and returns
-- the value, or nil and an error message. `decoders` holds the decoding function of every type
-- id, and `decoders.string` reads a value that has to be a string.
--
-- `Decoder.decode` itself reads with functions that take the bytes, a position and the last
-- position they may read, and return the value and the position after it. It only fills a
-- context for the decoders of custom types, and it never raises an error for the bytes it is
-- given.
const Decoder = {
  decoders = decoders
}

do
  const FLOAT_POW2 = POW2_BIAS - 150
  const DOUBLE_POW2 = POW2_BIAS - 1023
  const MANTISSA_SCALE = pow2[POW2_BIAS - 52]

  const context = { 1, '', 0, INFINITY }

  --- What `size` is in `get_table` while the pairs of a table are read.
  const HASH = -1

  --- What `get_table` keeps in place of a key under a table that is read as a key.
  const KEY_MARK = {}

  --- Error message of the read that failed last.
  local failure

  --- Fails a read that would end at `stop`, past the last position it may read.
  -- @return [Nil no value, Nil no position]
  local function out_of_bytes(str, stop)
    if stop > #str then
      failure = 'bytes underflow'
    else
      failure = 'bytes overflow'
    end

    return nil, nil
  end

  --- Reads a value with the decoder of the custom type of an id, which gets the shared context.
  -- What the context held is put back afterwards, so a decoder that decodes other data leaves
  -- the reads around it intact. A decoder that raises an error or that does not move the read
  -- position forward fails the read.
  -- @return [Any the value, Number position after it; two nils when there is no decoder or it
  --   fails]
  local function get_custom(str, pos, limit, id)
    local decoder = decoders[id]

    if decoder == nil then
      failure = 'unsupported type: '..id

      return nil, nil
    end

    local ctx = context
    local outer_pos, outer_str, outer_len, outer_limit = ctx[1], ctx[2], ctx[3], ctx[4]

    ctx[1], ctx[2], ctx[3], ctx[4] = pos, str, #str, limit

    local ok, val, err = pcall(decoder, ctx)
    local next_pos = ctx[1]

    ctx[1], ctx[2], ctx[3], ctx[4] = outer_pos, outer_str, outer_len, outer_limit

    if !ok then
      failure = val or 'custom decoder failed'

      return nil, nil
    elseif err then
      failure = err

      return nil, nil
    elseif next_pos == nil or tonumber(next_pos) != next_pos or next_pos <= pos then
      failure = 'custom decoder did not move the read position forward'

      return nil, nil
    end

    return val, next_pos
  end

  local get_table

  --- Reads the value at a position.
  -- @param str [String bytes to read from]
  -- @param pos [Number position of the type id of the value]
  -- @param limit [Number last position that may be read]
  -- @return [Any the value, Number position after it; two nils when the read fails, with the
  --   error message in `failure`]
  local function get_value(str, pos, limit)
    if pos > limit then
      return out_of_bytes(str, pos)
    end

    local id = string_byte(str, pos)

    if id <= POSITIVE_FIXED_END then
      return id - POSITIVE_FIXED_START, pos + 1
    elseif id <= STRING_FIXED_END then
      local stop = pos + id - STRING_FIXED_START

      if stop > limit then
        return out_of_bytes(str, stop)
      end

      return string_sub(str, pos + 1, stop), stop + 1
    elseif id == NEGATIVE_FIXED_START then
      return NEGATIVE_ZERO, pos + 1
    elseif id <= NEGATIVE_FIXED_END then
      return NEGATIVE_FIXED_START - id, pos + 1
    elseif id <= ARRAY_AND_TABLE then
      return get_table(str, pos + 1, limit, id)
    end

    local reader = readers[id]

    if reader then
      return reader(str, pos, limit)
    end

    return get_custom(str, pos, limit, id)
  end

  --- Returns an empty table for one of the three table ids, the amount of values in its array or
  -- `HASH` when it starts with its pairs, and whether pairs follow its array. An array starts
  -- with room for eight values, which spares short lists from growing.
  local function open_table(id)
    if id == TABLE then
      return {}, HASH, false
    end

    return { nil, nil, nil, nil, nil, nil, nil, nil }, 0, id == ARRAY_AND_TABLE
  end

  --- Reads a table and every table inside it in one loop: the tables that are still open wait
  -- on a stack, four slots each, instead of in calls of their own. That leaves the JIT compiler
  -- a single loop that reads small integers and short strings without a call, and data that is
  -- nested deeply costs memory instead of call depth.
  --
  -- `tbl` is the innermost open table and `size` the amount of values read into its array, or
  -- `HASH` while its pairs are read; `mixed` is set while pairs follow the array. `key` is the
  -- key of the pair whose value is read next, and `KEY_MARK` on the stack under a table that is
  -- itself a key. Keys that cannot index a table, nil and NaN, fail the read.
  --
  -- The end of the outermost table is tested for on its own, ahead of everything else: the
  -- trace that returns from here runs on into the caller and LuaJIT 2.0 gives it up when the
  -- caller does something it does not compile, which would take every other value that leaves
  -- the loop by the same test back to the interpreter.
  -- @param str [String bytes to read from]
  -- @param pos [Number position after the type id of the table]
  -- @param limit [Number last position that may be read]
  -- @param id [Number type id of the table]
  -- @return [Map the table, Number position after it; two nils when the read fails, with the
  --   error message in `failure`]
  function get_table(str, pos, limit, id)
    local tbl, size, mixed = open_table(id)
    local level = 0
    local key, stack

    while true do
      if pos > limit then
        return out_of_bytes(str, pos)
      end

      id = string_byte(str, pos)

      if level == 0 and id == ENDING and key == nil and !mixed then
        return tbl, pos + 1
      end

      if size == HASH and key == nil and id != ENDING then
        if id > NEGATIVE_FIXED_END and id <= ARRAY_AND_TABLE then
          key = KEY_MARK
        else
          if id >= STRING_FIXED_START and id <= STRING_FIXED_END then
            local stop = pos + id - STRING_FIXED_START

            key = string_sub(str, pos + 1, stop)
            pos = stop + 1
          else
            key, pos = get_value(str, pos, limit)

            if key == nil or key != key then
              if pos != nil then
                failure = 'invalid table key'
              end

              return nil, nil
            end
          end

          if pos > limit then
            return out_of_bytes(str, pos)
          end

          id = string_byte(str, pos)
        end
      end

      if id > NEGATIVE_FIXED_END and id <= ARRAY_AND_TABLE then
        local top = level * 4

        stack = stack or {}
        stack[top + 1], stack[top + 2], stack[top + 3], stack[top + 4] = tbl, size, key, mixed
        tbl, size, mixed = open_table(id)
        key = nil
        level += 1
        pos += 1
      elseif mixed and id == ENDING then
        mixed = false
        size = HASH
        pos += 1
      else
        local val

        if id <= POSITIVE_FIXED_END then
          val = id - POSITIVE_FIXED_START
          pos += 1
        elseif id <= STRING_FIXED_END then
          local stop = pos + id - STRING_FIXED_START

          if stop > limit then
            return out_of_bytes(str, stop)
          end

          val = string_sub(str, pos + 1, stop)
          pos = stop + 1
        elseif id <= NEGATIVE_FIXED_END then
          if id == NEGATIVE_FIXED_START then
            val = NEGATIVE_ZERO
          else
            val = NEGATIVE_FIXED_START - id
          end

          pos += 1
        elseif id == ENDING then
          if key != nil then
            failure = 'unsupported type: '..ENDING

            return nil, nil
          end

          local top = level * 4 - 4

          val = tbl
          tbl, size, key, mixed = stack[top + 1], stack[top + 2], stack[top + 3], stack[top + 4]
          level -= 1
          pos += 1
        else
          local reader = readers[id]

          if reader then
            val, pos = reader(str, pos, limit)
          else
            val, pos = get_custom(str, pos, limit, id)
          end

          if pos == nil then
            return nil, nil
          end
        end

        if key == KEY_MARK then
          key = val
        elseif size == HASH then
          tbl[key] = val
          key = nil
        else
          size += 1
          tbl[size] = val
        end
      end
    end
  end

  readers[NIL] = function(_str, pos)
    return nil, pos + 1
  end

  readers[FALSE] = function(_str, pos)
    return false, pos + 1
  end

  readers[TRUE] = function(_str, pos)
    return true, pos + 1
  end

  --- Reads an unsigned integer from the byte at a position.
  -- @return [Number the integer, Number position after it; two nils on failure]
  local function get_u8(str, pos, limit)
    if pos > limit then
      return out_of_bytes(str, pos)
    end

    return string_byte(str, pos), pos + 1
  end

  --- Reads an unsigned integer from the two big-endian bytes at a position.
  -- @return [Number the integer, Number position after it; two nils on failure]
  local function get_u16(str, pos, limit)
    local stop = pos + 1

    if stop > limit then
      return out_of_bytes(str, stop)
    end

    local b1, b2 = string_byte(str, pos, stop)

    return b1 * 0x100 + b2, stop + 1
  end

  --- Reads an unsigned integer from the four big-endian bytes at a position.
  -- @return [Number the integer, Number position after it; two nils on failure]
  local function get_u32(str, pos, limit)
    local stop = pos + 3

    if stop > limit then
      return out_of_bytes(str, stop)
    end

    local b1, b2, b3, b4 = string_byte(str, pos, stop)

    return b1 * 0x1000000 + (b2 << 16 | b3 << 8 | b4), stop + 1
  end

  --- Reads an unsigned integer from the seven big-endian bytes at a position.
  -- @return [Number the integer, Number position after it; two nils on failure]
  local function get_u53(str, pos, limit)
    local stop = pos + 6

    if stop > limit then
      return out_of_bytes(str, stop)
    end

    local b1, b2, b3, b4, b5, b6, b7 = string_byte(str, pos, stop)

    return (b1 << 16 | b2 << 8 | b3) * 0x100000000 + b4 * 0x1000000 + (b5 << 16 | b6 << 8 | b7), stop + 1
  end

  --- Returns the number that the four bytes of an IEEE 754 single-precision float stand for.
  -- Zero, subnormal and normal floats of either sign take the same path through it: the
  -- exponent field 0 scales like 1 without the implicit bit, and the sign is a factor. That
  -- spares the JIT compiler a side trace for every kind, which it cannot always build inside a
  -- reader that holds many bytes.
  local function bytes_to_float(b1, b2, b3, b4)
    local exponent = (b1 & 0x7F) << 1 | b2 >> 7
    local mantissa = (b2 & 0x7F) << 16 | b3 << 8 | b4

    if exponent == 0xFF then
      if mantissa != 0 then
        return NAN
      end

      return INFINITY * (1 - (b1 >> 7) * 2)
    end

    return (mantissa + (math_min(exponent, 1) << 23)) * pow2[FLOAT_POW2 + math_max(exponent, 1)] * (1 - (b1 >> 7) * 2)
  end

  --- Reads an IEEE 754 single-precision float from the four big-endian bytes at a position.
  -- @return [Number the float, Number position after it; two nils on failure]
  local function get_float(str, pos, limit)
    local stop = pos + 3

    if stop > limit then
      return out_of_bytes(str, stop)
    end

    return bytes_to_float(string_byte(str, pos, stop)), stop + 1
  end

  --- Reads an IEEE 754 double-precision float from the eight big-endian bytes at a position. As
  -- in `bytes_to_float`, the exponent field 0 scales like 1 without the implicit bit and the
  -- sign is a factor.
  -- @return [Number the number, Number position after it; two nils on failure]
  local function get_double(str, pos, limit)
    local stop = pos + 7

    if stop > limit then
      return out_of_bytes(str, stop)
    end

    local b1, b2, b3, b4, b5, b6, b7, b8 = string_byte(str, pos, stop)
    local exponent = (b1 & 0x7F) << 4 | b2 >> 4
    local mantissa = ((b2 & 0xF) << 16 | b3 << 8 | b4) * 0x100000000 + b5 * 0x1000000 + (b6 << 16 | b7 << 8 | b8)
    local sign = 1 - (b1 >> 7) * 2

    if exponent == 0x7FF then
      if mantissa != 0 then
        return NAN, stop + 1
      end

      return INFINITY * sign, stop + 1
    end

    return (mantissa * MANTISSA_SCALE + math_min(exponent, 1)) * pow2[DOUBLE_POW2 + math_max(exponent, 1)] * sign,
        stop + 1
  end

  --- Returns a reader that skips the type id and returns what `read` reads after it.
  local function after_id(read)
    return |str, pos, limit| -> read(str, pos + 1, limit)
  end

  --- Returns a reader that skips the type id and negates the integer `read` reads after it.
  local function negated_after_id(read)
    return function(str, pos, limit)
      local num, next_pos = read(str, pos + 1, limit)

      if next_pos == nil then
        return nil, nil
      end

      return -num, next_pos
    end
  end

  --- Returns a reader that skips the type id and reads a string of the length `read_length`
  -- reads after it.
  local function string_after_id(read_length)
    return function(str, pos, limit)
      local str_len, start = read_length(str, pos + 1, limit)

      if start == nil then
        return nil, nil
      end

      local stop = start + str_len - 1

      if stop > limit then
        return out_of_bytes(str, stop)
      end

      return string_sub(str, start, stop), stop + 1
    end
  end

  readers[POSITIVE_U8] = after_id(get_u8)
  readers[POSITIVE_U16] = after_id(get_u16)
  readers[POSITIVE_U32] = after_id(get_u32)
  readers[POSITIVE_U53] = after_id(get_u53)

  readers[NEGATIVE_U8] = negated_after_id(get_u8)
  readers[NEGATIVE_U16] = negated_after_id(get_u16)
  readers[NEGATIVE_U32] = negated_after_id(get_u32)
  readers[NEGATIVE_U53] = negated_after_id(get_u53)

  readers[STRING_U8] = string_after_id(get_u8)
  readers[STRING_U16] = string_after_id(get_u16)
  readers[STRING_U32] = string_after_id(get_u32)

  readers[FLOAT] = after_id(get_float)
  readers[DOUBLE] = after_id(get_double)

  const Entity = Entity

  readers[ENTITY] = function(str, pos, limit)
    local stop = pos + 2

    if stop > limit then
      return out_of_bytes(str, stop)
    end

    local b1, b2 = string_byte(str, pos + 1, stop)
    local index = b1 << 8 | b2

    if index == NULL_ENT_INDEX + 0x10000 then
      return NULL, stop + 1
    elseif index > 0x8000 then
      index -= 0x10000
    end

    return Entity(index), stop + 1
  end

  --- Reads a player by its index. Index 0 is a player that had left when it was written.
  readers[PLAYER] = function(str, pos, limit)
    local stop = pos + 1

    if stop > limit then
      return out_of_bytes(str, stop)
    end

    local index = string_byte(str, stop)

    if index == 0 then
      return NULL, stop + 1
    end

    return Entity(index), stop + 1
  end

  --- Returns a reader that passes the three floats after the type id to `create`.
  local function triple_reader(create)
    return function(str, pos, limit)
      local stop = pos + 12

      if stop > limit then
        return out_of_bytes(str, stop)
      end

      local x = bytes_to_float(string_byte(str, pos + 1, pos + 4))
      local y = bytes_to_float(string_byte(str, pos + 5, pos + 8))

      return create(x, y, bytes_to_float(string_byte(str, pos + 9, stop))), stop + 1
    end
  end

  readers[VECTOR] = triple_reader(Vector)
  readers[ANGLE] = triple_reader(Angle)

  const Matrix = Matrix

  readers[MATRIX] = function(str, pos, limit)
    local stop = pos + 64

    if stop > limit then
      return out_of_bytes(str, stop)
    end

    local rows = {}

    for i = 1, 4 do
      local row = {}

      for j = 1, 4 do
        pos += 4
        row[j] = bytes_to_float(string_byte(str, pos - 3, pos))
      end

      rows[i] = row
    end

    return Matrix(rows), stop + 1
  end

  const color_meta = FindMetaTable and FindMetaTable('Color')
  const setmetatable = setmetatable

  --- Reads a color into a table with the metatable of colors, which is what `Color` returns for
  -- channels that are bytes.
  readers[COLOR] = function(str, pos, limit)
    local stop = pos + 4

    if stop > limit then
      return out_of_bytes(str, stop)
    end

    local r, g, b, a = string_byte(str, pos + 1, stop)

    return setmetatable({ r = r, g = g, b = b, a = a }, color_meta), stop + 1
  end

  --- Returns the last position that reads from a context may reach: the smallest of the length
  -- it gives, its size limit and the length its bytes really have.
  local function context_limit(ctx)
    local limit = #ctx[2]

    if ctx[3] < limit then
      limit = ctx[3]
    end

    if ctx[4] < limit then
      return ctx[4]
    end

    return limit
  end

  --- Moves a context past a value that one of the reading functions returned.
  -- @return [Any the value, or nil and String error message]
  local function advance(ctx, val, pos)
    if pos == nil then
      return nil, failure
    end

    ctx[1] = pos

    return val
  end

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

  --- Reads the value at the read position.
  -- @param ctx [List context to read from]
  -- @return [Any the value, or nil and String error message]
  function Decoder.read_value(ctx)
    return advance(ctx, get_value(ctx[2], ctx[1], context_limit(ctx)))
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

  --- Reads an unsigned integer from one byte.
  -- @param ctx [List context to read from]
  -- @return [Number the integer, or nil and String error message]
  function Decoder.read_u8(ctx)
    return advance(ctx, get_u8(ctx[2], ctx[1], context_limit(ctx)))
  end

  --- Reads an unsigned integer from two big-endian bytes.
  -- @param ctx [List context to read from]
  -- @return [Number the integer, or nil and String error message]
  function Decoder.read_u16(ctx)
    return advance(ctx, get_u16(ctx[2], ctx[1], context_limit(ctx)))
  end

  --- Reads an unsigned integer from four big-endian bytes.
  -- @param ctx [List context to read from]
  -- @return [Number the integer, or nil and String error message]
  function Decoder.read_u32(ctx)
    return advance(ctx, get_u32(ctx[2], ctx[1], context_limit(ctx)))
  end

  --- Reads an unsigned integer from seven big-endian bytes.
  -- @param ctx [List context to read from]
  -- @return [Number the integer, or nil and String error message]
  function Decoder.read_u53(ctx)
    return advance(ctx, get_u53(ctx[2], ctx[1], context_limit(ctx)))
  end

  --- Reads an unsigned integer with `read` and returns it as the signed integer it stands for in
  -- two's complement.
  local function read_signed(ctx, read, sign_bit)
    local num, err = read(ctx)

    if err then return nil, err end

    if num >= sign_bit then
      return num - sign_bit * 2
    end

    return num
  end

  --- Reads a signed integer from one byte in two's complement.
  -- @param ctx [List context to read from]
  -- @return [Number the integer, or nil and String error message]
  function Decoder.read_i8(ctx)
    return read_signed(ctx, Decoder.read_u8, 0x80)
  end

  --- Reads a signed integer from two big-endian bytes in two's complement.
  -- @param ctx [List context to read from]
  -- @return [Number the integer, or nil and String error message]
  function Decoder.read_i16(ctx)
    return read_signed(ctx, Decoder.read_u16, 0x8000)
  end

  --- Reads a signed integer from four big-endian bytes in two's complement.
  -- @param ctx [List context to read from]
  -- @return [Number the integer, or nil and String error message]
  function Decoder.read_i32(ctx)
    return read_signed(ctx, Decoder.read_u32, 0x80000000)
  end

  --- Reads a signed 53-bit integer from seven big-endian bytes in two's complement.
  -- @param ctx [List context to read from]
  -- @return [Number the integer, or nil and String error message]
  function Decoder.read_i53(ctx)
    return read_signed(ctx, Decoder.read_u53, 0x10000000000000)
  end

  --- Reads an IEEE 754 single-precision float from four big-endian bytes.
  -- @param ctx [List context to read from]
  -- @return [Number the float, or nil and String error message]
  function Decoder.read_float(ctx)
    return advance(ctx, get_float(ctx[2], ctx[1], context_limit(ctx)))
  end

  --- Reads an IEEE 754 double-precision float from eight big-endian bytes.
  -- @param ctx [List context to read from]
  -- @return [Number the number, or nil and String error message]
  function Decoder.read_double(ctx)
    return advance(ctx, get_double(ctx[2], ctx[1], context_limit(ctx)))
  end

  --- Reads values into a list until the type id `till`, and moves the read position past it.
  -- @param ctx [List context to read from]
  -- @param till [Number type id that ends the list]
  -- @return [List<Any> the list, or nil and String error message, Number amount of values read]
  function Decoder.read_array(ctx, till)
    local arr = { nil, nil, nil, nil, nil, nil, nil, nil }
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

  --- Reads keys and their values into a table until the type id `till`, and moves the read
  -- position past it. Keys that cannot index a table, nil and NaN, fail the read.
  -- @param ctx [List context to read from]
  -- @param till [Number type id that ends the table]
  -- @return [Map the table, or nil and String error message]
  function Decoder.read_table(ctx, till)
    local tbl = {}

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

  --- Points the shared context at a string, for reading it with the functions of `Decoder`.
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

  --- Decodes a string made by `Encoder.encode`. Malformed data and errors raised by the decoders
  -- of custom types come back as an error message.
  -- @alias [NFS.decode]
  -- @param bytes [String data to decode]
  -- @param max_size=math.huge [Number size past which decoding fails]
  -- @return [Any the value, or nil and String error message]
  function Decoder.decode(bytes, max_size)
    if getmetatable(bytes) != STRING_META and !isstring(bytes) then
      return nil, 'bytes must be a string'
    end

    local limit = #bytes

    if max_size != nil then
      if tonumber(max_size) != max_size and !isnumber(max_size) then
        return nil, 'max_size must be a number'
      elseif max_size < 1 then
        return nil, 'max_size must be greater than 0'
      elseif max_size < limit then
        limit = max_size
      end
    end

    if limit < 1 then
      return nil, 'no bytes to decode'
    end

    local val, pos = get_value(bytes, 1, limit)

    if pos == nil then
      return nil, failure
    end

    return val
  end

  for type_id = 0, CUSTOM_START - 1 do
    if type_id != ENDING then
      decoders[type_id] = read_value
    end
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
  const string_format = string.format
  const string_gsub = string.gsub
  const string_lower = string.lower

  --- Two hexadecimal digits by the character they stand for.
  const hex_of = {}

  --- Characters by their two hexadecimal digits, in either case.
  const char_of = {}

  for i = 0, 255 do
    local upper = string_format('%02X', i)
    local lower = string_lower(upper)
    local char = chars[i]

    hex_of[char] = upper
    char_of[upper] = char
    char_of[lower] = char
    char_of[string_sub(upper, 1, 1)..string_sub(lower, 2, 2)] = char
    char_of[string_sub(lower, 1, 1)..string_sub(upper, 2, 2)] = char
  end

  --- Encodes a value into a string of hexadecimal digits, two per byte.
  -- @param val [Any value to encode]
  -- @return [String encoded data, or nil and String error message]
  function NFS.encode_to_hex(val)
    local encoded, err = Encoder.encode(val)

    if err then return nil, err end

    return (string_gsub(encoded, '.', hex_of))
  end

  --- Decodes a string of hexadecimal digits made by `NFS.encode_to_hex`.
  -- @param str [String encoded data]
  -- @return [Any the value, or nil and String error message]
  function NFS.decode_from_hex(str)
    if !isstring(str) then
      return nil, 'hex data must be a string'
    end

    local bytes, pair_count = string_gsub(str, '%x%x', char_of)

    if pair_count * 2 != #str then
      return nil, 'invalid hex data'
    end

    return Decoder.decode(bytes)
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

--- Replaces the function the encoder names the type of a value with. The encoder only asks it
-- about values that are not nil, a boolean, a number or a string and whose metatable has no
-- encoder. The function it starts with is not asked about tables either.
-- @param type_function [Function returns the type name of the value it is given]
function NFS.set_type_function(type_function)
  type = type_function
  engine_type = false
end

--- Stores the encoder and the decoder of a custom type, and has the encoder and the decoder stop
-- handling the type and the id in place. An encoder for the name of an engine type also replaces
-- the one found by the metatable of that type.
local function set_custom_type(type_id, type_key, encoder, decoder)
  local meta = engine_metas[type_key]

  if meta then
    encoders[meta] = encoder
  end

  if type_key == 'string' or type_key == STRING_META then
    string_meta = {}
  elseif type_key == 'nil' or type_key == 'boolean' or type_key == 'number' then
    inline_primitives = false
  end

  encoders[type_key] = encoder
  decoders[type_id] = decoder
  readers[type_id] = false
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

  set_custom_type(type_id, type_key, encoder, decoder)
  next_custom_type += 1

  return type_id
end

--- Sets the encoder and the decoder of a custom type under a type id of the caller's choice, for
-- ids that have to stay the same whatever order types are added in. Taking a type that has an
-- encoder or an id that has a decoder already prints a warning and replaces them. The ids of
-- small integers, of short strings, of tables and of `ending` are read in place: they cannot be
-- taken and raise an error.
-- @param type_id [Number type id of the custom type]
-- @param type_key [String/Map type name or metatable of the values the encoder is for]
-- @param encoder [Function writes a value into a buffer]
-- @param decoder [Function reads a value from a context]
function NFS.set_custom_type_with_id(type_id, type_key, encoder, decoder)
  if readers[type_id] == nil or type_id <= ENDING then
    error('type id cannot be taken: '..tostring(type_id), 2)
  end

  if encoders[type_key] or decoders[type_id] then
    ErrorNoHaltWithStack('type already exists: `'..tostring(type_key)..'`')
  end

  set_custom_type(type_id, type_key, encoder, decoder)
end

return NFS
