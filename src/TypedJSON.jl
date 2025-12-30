module TypedJSON

#=
This module aims to perform JSON (de-)serialization of Julia objects
fostering predicatbility of results rather than out-of-the-box
compatibility with any possible Julia types.

The serialized JSON stream contains additional meta data supposed to
assist in properly de-serialize the object (see `jtype` below).

Note however that this module does not guarantee de-serialized objects
will be identical to the original ones, but it is possible to
implement new `lower` and `reconstruct` methods to achieve perfect
consistency.
=#

using DataStructures, Dates, JSON, GZip

#=
Basic JSON types are: null, number, string, boolean, vector and dictionary (or objects).
Here we define a Julia structure for each of these types.

Their purpose is to act as a bridge between the Julia world and the
JSON format: if you can transform a Julia object into one of these
objects, then the Julia object can be serialized in JSON. (note:
deserialization is not guaranteed)

Note that for numeric values we define two different sutrctures to
distinguish integers from floating point numbers.

Also for the dictionary or object type we define three
different structures to distinguish the following cases:
- A singleton value;
- A value represented by a single JSONType structure;
- A more complex value requiring a dictionary (e.g. a dictionary, a named tuple or a structure);

In total, we have 8 different structures to represent a julia object into the JSON format.
=#
abstract type JSONType end

struct JSONNull <: JSONType
end

abstract type JSONNumber <: JSONType end

struct JSONInt <: JSONNumber
    value::Int
end

struct JSONFloat <: JSONNumber
    value::Float64
end

struct JSONString <: JSONType
    value::String
    JSONString(v) = new(string(v))
end

struct JSONBool <: JSONType
    value::Bool
end

struct JSONArray <: JSONType
    value::Vector{<: JSONType}
end

abstract type JSONObject <: JSONType end

struct JSONSingleton <: JSONObject
    jtype::Symbol
end

struct JSONValue <: JSONObject
    jtype::Symbol
    value::JSONType
    JSONValue(juliatype::Symbol, value::JSONType) = new(juliatype, value)
end

struct JSONDict <: JSONObject
    jtype::Symbol
    dict::OrderedDict{Symbol, JSONType}
    JSONDict(juliatype::Symbol, dict::OrderedDict{Symbol, JSONType}) = new(juliatype, dict)

    function JSONDict(str::T) where {T}
        @assert isstructtype(T) "Type $T is not a structure"
        dict = OrderedDict{Symbol, JSONType}()
        for key in fieldnames(T)
            dict[Symbol(key)] = lower(getfield(str, key))
        end
        jtype = Symbol(string(parentmodule(T)) * "." * string(nameof(T)))
        return new(jtype, dict)
    end
end


#=====================================================================
Lower methods.

These are used to transform a Julia object into one of the `JSONType`s
defined above.  User may define new `lower` methods to support additional
Julia types.
=#
lower(::Nothing) = JSONNull()
lower(v::String) = JSONString(v)
lower(v::Bool) = JSONBool(v)
lower(v::AbstractVector) = JSONArray(lower.(v))
function lower(v::T) where {T}
    @assert isstructtype(T) "Attempted to invoke the `lower` method for a structurre but $T is not a structure, consider defining a new JSONSerializer.lower(::$(T)) method"
    return JSONDict(v)
end

function check_special_value(v::AbstractFloat)
    if isnan(v)
        return JSONSingleton(:NaN)
    elseif isinf(v)
        if v > 0
            return JSONSingleton(:pInf)
        else
            return JSONSingleton(:mInf)
        end
    end
    return nothing
end


lower(v::BigInt)   = return JSONValue(:BigInt  , JSONString(v))
lower(v::Int128)   = return JSONValue(:Int128  , JSONString(v))
lower(v::Int64)    = return JSONInt(v)
lower(v::Int32)    = return JSONValue(:Int32   , JSONInt(v))
lower(v::Int16)    = return JSONValue(:Int16   , JSONInt(v))
lower(v::Int8)     = return JSONValue(:Int8    , JSONInt(v))
lower(v::UInt128)  = return JSONValue(:UInt128 , JSONString(v))
lower(v::UInt64)   = return JSONValue(:UInt64  , JSONString(v))
lower(v::UInt32)   = return JSONValue(:UInt32  , JSONInt(v))
lower(v::UInt16)   = return JSONValue(:UInt16  , JSONInt(v))
lower(v::UInt8)    = return JSONValue(:UInt8   , JSONInt(v))
function lower(v::BigFloat); sv = check_special_value(v); return !isnothing(sv)  ?  sv  :  JSONValue(:BigFloat, JSONString(v)); end
function lower(v::Float64) ; sv = check_special_value(v); return !isnothing(sv)  ?  sv  :  JSONFloat(v)                       ; end
function lower(v::Float32) ; sv = check_special_value(v); return !isnothing(sv)  ?  sv  :  JSONValue(:Float32 , JSONFloat(v)) ; end
function lower(v::Float16) ; sv = check_special_value(v); return !isnothing(sv)  ?  sv  :  JSONValue(:Float16 , JSONFloat(v)) ; end

lower(::Missing) = JSONSingleton(:Missing)
lower(v::Char) = return JSONValue(:Char, JSONString(v))
lower(v::Expr) = return JSONValue(:Expr, JSONString(v))
lower(v::Date) = return JSONValue(:Date, JSONString(v))
lower(v::DateTime) = return JSONValue(:DateTime, JSONString(v))
lower(v::Symbol) = return JSONValue(:Symbol, JSONString(v))
lower(v::Tuple) = JSONValue(:Tuple, JSONArray([lower.(v)...]))

function lower(input::T) where {T <: AbstractDict}
    dict = OrderedDict{Symbol, JSONType}()
    for (key, val) in input
        dict[Symbol(key)] = lower(val)
    end
    return JSONDict(:OrderedDict, dict)
end

function lower(input::NamedTuple)
    dict = OrderedDict{Symbol, JSONType}()
    for (key, val) in pairs(input)
        dict[Symbol(key)] = lower(val)
    end
    return JSONDict(:NamedTuple, dict)
end


#=====================================================================
The `format` methods are used to transform the `JSONType`s structures
defined above into Julia types suitable to be serialized by the adopted
JSON library.

We need exactly one `format` method for each of the JSONType
structures, and users are not supposed to add new ones.

Note: in some case the `lower` and `format` methods perform very
simple conversions back and forth between, e.g. `nothing` and
`JSONNull`, a number and `JSONNumber`, etc.  This additional overhead
is necessary to ensure that more complex Julia objects can be
serialized in a predictable way, i.e. exclusively the `JSONType`s
defined above.
=#

const TYPE = ":"
const OBJ = ""

format(v::JSONNull) = nothing
format(v::JSONInt) = v.value
format(v::JSONFloat) = v.value
format(v::JSONString) = v.value
format(v::JSONBool) = v.value
format(v::JSONArray) = format.(v.value)
format(v::JSONSingleton) = OrderedDict{String, Any}(TYPE => v.jtype)
format(v::JSONValue) = OrderedDict{String, Any}(TYPE => v.jtype, OBJ => format(v.value))
function format(v::JSONDict)
    out = OrderedDict{String, Any}()
    out[TYPE] = v.jtype
    out[OBJ] = OrderedDict{Symbol, Any}()
    for (key, val) in v.dict
        out[OBJ][key] = format(val)
    end
    return out
end


#=====================================================================
Actual seralization method.

The julia data are:
- lowered into a number of `JSONType` structures;
- formatted into a form suitable to be serialized;
- serialized in JSON;
- written on file.
=#

"""
    serialize(filename::String, data; compress=false)

Serializes a Julia object `data` into the `filename` JSON file. Unlike standard JSON serialization, this function wraps values in metadata with the aim of preserving types like `Date`, `Symbol`, `NaN`, `Inf`, custom structures, etc.).

# Arguments
- `filename::String`: The path where the file will be saved.
- `data`: The Julia object to serialize.

## Keyword Arguments
- `compress::Bool`: If `true`, the output is compressed using GZip. If `false` (default), compression is determined by the file extension (encables compression if filename ends in `.gz`).

# Example
```julia
data = (id=1, date=now(), val=NaN)
TypedJSON.serialize("data.json", data)
```
"""
serialize(filename::String, data; kws...) = serialize(filename, lower(data); kws...)
function serialize(filename::String, data::JSONType; compress=false)
    if compress  ||  ((length(filename) >= 3)  &&  (filename[(end-2):end] == ".gz"))
        io = GZip.open(filename, "w")
    else
        io = open(filename, "w")
    end
    JSON.json(io, format(data))
    close(io)
    return filename
end


#=====================================================================
The `parse` methods perform the opposite conversion of the `format`
methods defined above, i.e. we expect `parse(format(v))` `v` to
indistinguishable.

We need exactly one `parse` method for each of the types returned by
the adopted JSON library, and users are not supposed to add new ones.

All `parse` methods shall return a single `JSONType` structure.
=#
parse(::Nothing) = JSONNull()
parse(v::Integer) = JSONInt(v)
parse(v::AbstractFloat) = JSONFloat(v)
parse(v::String) = JSONString(v)
parse(v::Bool) = JSONBool(v)
function parse(v::Vector)
    if length(v) == 0
        return JSONArray(Vector{JSONNull}())
    end
    return JSONArray(parse.(v))
end

function parse(input::OrderedDict)
    @assert TYPE in keys(input)
    jtype = Symbol(input[TYPE])
    if length(input) == 1
        return JSONSingleton(jtype)
    else
        @assert OBJ in keys(input)
        if !isa(input[OBJ], OrderedDict)
            return JSONValue(jtype, parse(input[OBJ]))
        else
            dict = OrderedDict{Symbol, JSONType}()
            for (key, val) in input[OBJ]
                dict[Symbol(key)] = parse(val)
            end
            return JSONDict(jtype, dict)
        end
    end
end


#=====================================================================
The `reconstruct` methods perform the opposite conversion of the
`lower` methods and are used to recreate the Julia objects based on
the provided `JSONType` input.

Hence we need at least 8 `reconstruct` methods, one for each of the
`JSONType` structures.

Actually we have several aditional `reconstruct` methods, one for each
Julia object we wish to de-serialize.  We dispatch the invocation
using either one of the `JSONType` structures, or the `Val{Symbol}`
stored in the `jtype` field of one of the `JSONSingleton`, `JSONValue`
and `JSONDict` structures.

User may define new `reconstruct` methods to support additional Julia
types.
=#
reconstruct(::JSONNull) = nothing
reconstruct(v::JSONString) = v.value
reconstruct(v::JSONBool) = v.value
reconstruct(v::JSONArray) = reconstruct.(v.value)
reconstruct(v::JSONSingleton) = reconstruct(Val(v.jtype))
reconstruct(v::JSONValue) = reconstruct(Val(v.jtype), reconstruct(v.value))
function reconstruct(v::JSONDict)
    dict = OrderedDict{Symbol, Any}()
    for (key, val) in v.dict
        dict[Symbol(key)] = reconstruct(val)
    end
    return reconstruct(Val(v.jtype), dict)
end


reconstruct(::Val{:BigInt}  , value) = Base.parse(BigInt, value)
reconstruct(::Val{:Int128}  , value) = Base.parse(Int128, value)
reconstruct(v::JSONInt) = v.value
reconstruct(::Val{:Int32}   , value) = Int32(value)
reconstruct(::Val{:Int16}   , value) = Int16(value)
reconstruct(::Val{:Int8}    , value) = Int8(value)
reconstruct(::Val{:UInt128} , value) = Base.parse(UInt128, value)
reconstruct(::Val{:UInt64}  , value) = Base.parse(UInt64, value)
reconstruct(::Val{:UInt32}  , value) = UInt32(value)
reconstruct(::Val{:UInt16}  , value) = UInt16(value)
reconstruct(::Val{:UInt8}   , value) = UInt8(value)
reconstruct(::Val{:BigFloat}, value) = BigFloat(value)
reconstruct(v::JSONFloat) = v.value
reconstruct(::Val{:Float32} , value) = Float32(value)
reconstruct(::Val{:Float16} , value) = Float16(value)

reconstruct(::Val{:Missing}) = missing
reconstruct(::Val{:Char}, value) = Char(value[1])
reconstruct(::Val{:Expr}, value) = Meta.parse(value)
reconstruct(::Val{:Date}, value) = Date(value)
reconstruct(::Val{:DateTime}, value) = DateTime(value)
reconstruct(::Val{:Symbol}, value) = Symbol(value)
reconstruct(::Val{:Tuple}, value) = tuple(value...)

reconstruct(::Val{:NaN}) = NaN
reconstruct(::Val{:pInf}) = +Inf
reconstruct(::Val{:mInf}) = -Inf

reconstruct(::Val{:OrderedDict}, dict) = dict
reconstruct(::Val{:NamedTuple}, dict) = NamedTuple(dict)


#=====================================================================
Actual deseralization method.

The JSON data are:
- read from file;
- parsed into a number of `JSONType` structures;

- converted into their original Julia data types (via the
  `reconstruct` methods).

Note: the last step can be skipped using
`attempt_reconstruction=false` (useful for debugging).  In this case
the `deserialize` method returns just the `JSONType` structure(s).
=#

"""
    deserialize(filename::String; attempt_reconstruction=true, compressed=false)

Reads a file created by `serialize` and reconstructs the original Julia objects.

# Arguments
- filename::String: The path to the file to read.

# Keyword Arguments
- `attempt_reconstruction::Bool`: If `true` (default), attempts to convert the loaded JSON metadata back into Julia types (e.g., Date, custom structs, etc). If `false`, returns the raw intermediate JSONType structures (useful for debugging schema changes).

- `compressed::Bool`: If true, enables GZip decompression. If `false` (default), it enables compression dependending on the presence of the `.gz` extension in the file name.

# Returns
 The reconstructed Julia object if `attempt_reconstruction` is `true`, otherwise it returns the internal structure used to wrap the data.

# Example
```julia
data = TypedJSON.deserialize("data.json")
```
"""
function deserialize(filename::String; attempt_reconstruction=true, compressed=false)
    if compressed  ||  ((length(filename) >= 3)  &&  (filename[(end-2):end] == ".gz"))
        io = GZip.open(filename)
    else
        io = open(filename)
    end
    parsed = parse(JSON.parse(io, dicttype=OrderedDict))
    close(io)

    if attempt_reconstruction
        return reconstruct(parsed)
    else
        return parsed
    end
end

end # module TypedJSON
