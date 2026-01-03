module TypedJSON

#=
This module aims to perform JSON (de-)serialization of Julia objects
fostering predicatbility of results rather than out-of-the-box
compatibility with any possible Julia types.

The serialized JSON stream contains additional meta data supposed to
assist in properly de-serialize the object (see `jtype` below).

Note however that this module does not guarantee de-serialized objects
to be identical to the original ones, but it is possible to
implement new `lower` and `reconstruct` methods to achieve perfect
consistency.
=#

using DataStructures, Dates, JSON, GZip

public serialize, deserialize, deserialize_json, roundtrip, prettyprint_json

#=
Basic JSON types are: null, number, string, boolean, vector and
dictionary (or objects), while Julia data types can be significantly
more complex.  As a consequence a simple conversion to/from JSON will
typically provide different types with respect to their original
values.

Here we define a limited number of Julia structures which can be
serialized/deserialized to/from JSON without any loss of type
information.

Their purpose is to act as an intermediate representation between the
Julia world and the JSON format: if you can transform a Julia object
into one of these object without loss of information, then the Julia
object can be safely deserialized in JSON preserving the types.

All such structures inherit from the abstract `JSONType`, hence we'll
call them `JSONType` structures.  In total, we have 9 such structures.
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

function lower(v::AbstractArray)
    dict = OrderedDict{Symbol, JSONType}()
    dict[:size] = lower(size(v))
    dict[:data] = lower(reshape(v, :))
    return JSONDict(:Array, dict)
end

function lower(v::T) where {T}
    @assert isstructtype(T) "Attempted to invoke the `lower` method for a structurre but $T is not a structure, consider defining a new JSONSerializer.lower(::$(T)) method"
    return JSONDict(v)
end


lower(v::BigInt)  = return JSONValue(:BigInt , JSONString(v))
lower(v::Int128)  = return JSONValue(:Int128 , JSONString(v))
lower(v::Int64)   = return JSONInt(v)
lower(v::Int32)   = return JSONValue(:Int32  , JSONInt(v))
lower(v::Int16)   = return JSONValue(:Int16  , JSONInt(v))
lower(v::Int8)    = return JSONValue(:Int8   , JSONInt(v))
lower(v::UInt128) = return JSONValue(:UInt128, JSONString(v))
lower(v::UInt64)  = return JSONValue(:UInt64 , JSONString(v))
lower(v::UInt32)  = return JSONValue(:UInt32 , JSONInt(v))
lower(v::UInt16)  = return JSONValue(:UInt16 , JSONInt(v))
lower(v::UInt8)   = return JSONValue(:UInt8  , JSONInt(v))

function lower(v::BigFloat)
    if isnan(v)
        d = JSONSingleton(:NaN)
    elseif isinf(v)
        d = (v > 0  ?  JSONSingleton(:pInf)  :  JSONSingleton(:mInf))
    else
        d = JSONString(v)
    end
    return JSONValue(:BigFloat, d)
end

function lower(v::Float64)
    if isnan(v)
        d = JSONSingleton(:NaN)
    elseif isinf(v)
        d = (v > 0  ?  JSONSingleton(:pInf)  :  JSONSingleton(:mInf))
    else
        d = JSONFloat(v)
    end
    return d
end

function lower(v::Float32)
    if isnan(v)
        d = JSONSingleton(:NaN)
    elseif isinf(v)
        d = (v > 0  ?  JSONSingleton(:pInf)  :  JSONSingleton(:mInf))
    else
        d = JSONFloat(v)
    end
    return JSONValue(:Float32, d)
end

function lower(v::Float16)
    if isnan(v)
        d = JSONSingleton(:NaN)
    elseif isinf(v)
        d = (v > 0  ?  JSONSingleton(:pInf)  :  JSONSingleton(:mInf))
    else
        d = JSONFloat(v)
    end
    return JSONValue(:Float16, d)
end

lower(::Missing) = JSONSingleton(:Missing)
lower(v::Char) = return JSONValue(:Char, JSONString(v))
lower(v::Expr) = return JSONValue(:Expr, JSONString(v))
lower(v::Date) = return JSONValue(:Date, JSONString(v))
lower(v::DateTime) = return JSONValue(:DateTime, JSONString(v))
lower(v::Symbol) = return JSONValue(:Symbol, JSONString(v))
lower(v::Tuple) = JSONValue(:Tuple, JSONArray([lower.(v)...]))

function lower(input::T) where {T <: Dict}
    dict = OrderedDict{Symbol, JSONType}()
    for (key, val) in input
        dict[Symbol(key)] = lower(val)
    end
    return JSONDict(:Dict, dict)
end

function lower(input::T) where {T <: OrderedDict}
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

# In a few cases there is no meaningful way to serialize data...
lower(::Function) = JSONNull()
lower(::IO) = JSONNull()
lower(::Ptr) = JSONNull()


#=====================================================================
The `format` methods are used to transform the `JSONType`s structures
defined above into Julia types suitable to be serialized by the adopted
JSON library.

We need exactly one `format` method for each of the JSONType
structures, and users are not supposed to add new ones.

Note: in some case the `lower` and `format` methods perform very
simple conversions back and forth between, e.g. `nothing` and
`JSONNull`, an integer and `JSONInt`, etc.  This additional overhead
is necessary to ensure that more complex Julia objects can be
serialized in a predictable way, i.e. using exclusively the
`JSONType`s defined above.
=#

const TYPE = ":"
const VAL = ""
const OBJ = "+"

format(v::JSONNull) = nothing
format(v::JSONInt) = v.value
format(v::JSONFloat) = v.value
format(v::JSONString) = v.value
format(v::JSONBool) = v.value
format(v::JSONArray) = format.(v.value)
format(v::JSONSingleton) = OrderedDict(TYPE => v.jtype)
format(v::JSONValue) = OrderedDict(TYPE => v.jtype, VAL => format(v.value))
function format(v::JSONDict)
    out = OrderedDict()
    out[TYPE] = v.jtype
    out[OBJ] = OrderedDict{Symbol, Any}()
    for (key, val) in v.dict
        out[OBJ][key] = format(val)
    end
    return out
end


# ====================================================================
# Seralization method.

"""
    serialize(filename::String, data; compress=false)
    serialize(io::IO, data)
    serialize(data)

Serializes a Julia object `data` into the `filename` JSON file or in the `io` stream.  If `filename` and `io` arguments are not provided it returns the JSON string.

# Arguments
- `filename::String`: The path where the file will be saved;
- `io::IO`: The IO stream to write JSON data;
- `data`: The Julia object to serialize.

## Keyword Arguments
- `compress::Bool`: If `true`, the output is compressed using GZip. If `false` (default), compression is determined by the file extension (enables compression if filename ends in `.gz`).

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
    serialize(io, data)
    close(io)
    return filename
end

serialize(io::IO, data)           = serialize(io, lower(data))
serialize(        data)           = serialize(    lower(data))

serialize(io::IO, data::JSONType) = JSON.json(io, format(data))
serialize(        data::JSONType) = JSON.json(    format(data))

#=====================================================================
The `parse` methods perform the opposite conversion of the `format`
methods defined above, i.e. we expect `parse(format(v))` and `v` to
be indistinguishable.

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
        if VAL in keys(input)
            return JSONValue(jtype, parse(input[VAL]))
        else
            @assert OBJ in keys(input)
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

Hence we need at least 9 `reconstruct` methods, one for each of the
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

reconstruct(::Val{:Dict}, dict::OrderedDict{K,V}) where {K,V} = convert(Dict{K,V}, dict)
reconstruct(::Val{:OrderedDict}, dict) = dict
reconstruct(::Val{:NamedTuple}, dict) = NamedTuple(dict)
reconstruct(::Val{:Array}, dict) = reshape(dict[:data], dict[:size])


# ====================================================================
# Deseralization methods.

"""
    deserialize(filename::String; compressed=false)

Reads a file created by `serialize` and reconstructs the original Julia object

# Arguments
- filename::String: The path to the file to read.

# Keyword Arguments
- `compressed::Bool`: If true, enables GZip decompression. If `false` (default), it enables compression dependending on the presence of the `.gz` extension in the file name.

# Returns
The reconstructed Julia object.

# Example
```julia
data = TypedJSON.deserialize("data.json")
```
"""
function deserialize(filename::String; compressed=false)
    if compressed  ||  ((length(filename) >= 3)  &&  (filename[(end-2):end] == ".gz"))
        io = GZip.open(filename)
    else
        io = open(filename)
    end
    out = deserialize_json(io)
    close(io)
    return out
end

"""
    deserialize_json(string::String)

Deserialize from a JSON string and reconstructs the original Julia object.

# Arguments
- `string::String`: The JSON string.

# Returns
The reconstructed Julia object.

# Example
```julia
data = TypedJSON.deserialize_json("[1,\\"two\\",3.0]")
```
"""
function deserialize_json(io::Union{String, IO})
    parsed = parse(JSON.parse(io, dicttype=OrderedDict))
    return reconstruct(parsed)
end

"""
    roundtrip(x, inspect_step=6)

Perform a complete serialization and deserialization of a Julia object, and allow to inspect data at intermediate steps.

The entire process involves the current steps:
1. convert the Julia object into an intermediate representation based on `JSONType` structures using the `lower` methods;
2. convert the `JSONType` structures into types suitable to be used as input for the `JSON library`;
3. actual JSON serialization via `JSON.json()`;
4. JSON de-serialization via `JSON.parse()`.  The data at this step are supposed to be equal (in the `isequal` sense) to those at step 2;
5. Parse data into the interemediate representation based on `JSONType` structures. The data at this step are supposed to be equal to those at step 1;
6. Recreate the original Julia data types using the `reconstruct` methods.  The data at this step are supposed to be equal to those provided in input (`x`).

# Arguments
- `x`: The JUlia object to serialize and deserialize;
- `inspect_step::Int`: return after the specified step has been performed.  Useful to inspect the data at an intermediate step.  Default value is 6.

# Returns
The data at the selected step.

# Example
```julia
data = TypedJSON.roundtrip([1,"two",3.0])
```
"""
function roundtrip(x, finalstep=6)
    s1 = lower(x);                             (finalstep == 1)  &&  (return s1)
    s2 = format(s1);                           (finalstep == 2)  &&  (return s2)
    s3 = JSON.json(s2);                        (finalstep == 3)  &&  (return s3)
    s4 = JSON.parse(s3, dicttype=OrderedDict); (finalstep == 4)  &&  (return s4)
    s5 = parse(s4);                            (finalstep == 5)  &&  (return s5)
    return reconstruct(s5)
end


"""
    prettyprint_json(x)

Pretty print the JKSON representation of the `x` object.

# Example
```julia
TypedJSON.prettyprint_json([1,"two",NaN])
```
"""
prettyprint_json(x) = JSON.print(JSON.parse(serialize(x)), 4)


end # module TypedJSON
