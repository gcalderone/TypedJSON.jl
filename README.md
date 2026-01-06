# TypedJSON.jl

**A Julia serialization library prioritizing type fidelity, human-readability, and long-term archival.**

`TypedJSON` allows you to serialize and deserialize Julia objects to/from JSON files.  But unlike other JSON libraries which convert data into generic strings or arrays, `TypedJSON` also stores metadata to attempt a proper reconstruction of data types.

The goal is similar to other serialization libraries such as the standard [Serialization](https://docs.julialang.org/en/v1/stdlib/Serialization/) or [JLD2](https://github.com/JuliaIO/JLD2.jl), but `TypedJSON` keeps the data in a human-readable form to ensure long term readability even if the definition of Julia structures evolve in time (version drift).

The following table shows a quick comparison between `TypedJSON` approach and a few other solutions for data serialization:

| **Feature** |  [`JLD2.jl`](https://github.com/JuliaIO/JLD2.jl) | [`JSON3.jl`](https://github.com/quinnj/JSON3.jl) | **TypedJSON** |
| :---    | :---  | :--- | :--- |
| **Output format**                                                    | Binary Blob       | Standard JSON   | Standard JSON (also includes metadata)            |
| **Human readable**                                                   | ❌ No             | ✅ Yes          | ✅ Yes                                            |
| **Type fidelity**                                                    | ✅ High           | ❌ Low          | ✅ High                                           |
| **Readability after change in structure definition**                 | ⚠️ Not guaranteed | ✅ Yes          | ✅ Yes (possibly redefining the `reconstruct` method) |
| **File storage efficiency**                                          | ✅ High           | ❌ Low          | ❌ Low (uncompressed) ✅ High (GZip compression)  |
| **Interoperability with other languages / libraries / applications** | ⚠️ Not guaranteed | ✅ Yes          | ✅ Yes                                            |
| **Require new method implementations for custom data types**         | ✅ No             | ❌ Yes          | ❌ Yes                                            |
---

The type-fidelity offered by `TypedJSON` comes at a price: the performance is likely worse than `JLD2` and `JSON3`.  Nevertheless, for sufficiently small data sets, or small frequency of use, the additional overhead is possibly negligible.


## Installation

```julia
using Pkg
Pkg.install("TypedJSON")
```


## Basic Usage

```julia
using Dates, TypedJSON

# Create data
data = (
    experiment = :alpha_run,      # Symbol
    timestamp = now(),            # DateTime
    readings = [1.0, NaN, Inf],   # Special Numerics
    config = (id=1, mode="fast")  # NamedTuple
)

# Save it (enable GZip compression if extension is .gz)
TypedJSON.serialize("experiment.json.gz", data)

# Load it back (types are restored automatically)
loaded_data = TypedJSON.deserialize("experiment.json.gz")

println(loaded_data.experiment) # :alpha_run (Symbol)
println(loaded_data.readings)   # [1.0, NaN, Inf]
```

### Compare with [`JSON.jl`](https://github.com/JuliaIO/JSON.jl)

A similar functionality may be obtained also with [`JSON.jl`](https://github.com/JuliaIO/JSON.jl), e.g.:
```julia
julia> JSON.parse(JSON.json(data, allownan=true), allownan=true)
JSON.Object{String, Any} with 4 entries:
  "experiment" => "alpha_run"
  "timestamp"  => "2026-01-05T14:21:27.182"
  "readings"   => Any[1.0, NaN, Inf]
  "config"     => Object{String, Any}("id"=>1.0, "mode"=>"fast")
```

Note however that some of the original types are lost (e.g. the deserialized data is no longer a `NamedTuple`, `alpha_run` is no longer a `Symbol` and `timestamp` is no longer a `DateTime`).  Also note that the generated JSON data is not compliant because of the `allownan=true`. Finally, note that the `TypedJSON.deserialize()` function never requires the user to specify a data type to properly parse the JSON data, since the type is stored as a metadata in the JSON itself.


## How `TypedJSON` fosters type-fidelity?

`TypedJSON` converts input data to an intermediate representation which can be serialized (deserialized) to (from) JSON format without loss of type information.  The conversion from the original Julia type to the intermediate representation is dubbed *lowering* and is performed via the `TypedJSON.lower` methods.  Typically there is no need to define additional `lower` methods for custom types, although this is definitely possible.

The inverse conversion, from the intermediate representation to the original Julia type, is dubbed *reconstruction* and is performed via the `TypedJSON.reconstruct` methods.  For user defined structs you need to define your own `reconstruct` method.


### `TypedJSON` internals

The `TypedJSON` intermediate representation (which is entirely unrelated to the [Julia intermediate representation](https://docs.julialang.org/en/v1/base/reflection/#Intermediate-and-compiled-representations)) is based on the following data structures:
- `JSONNull`: corresponding to the `nothing` singleton;
- `JSONInt`: a scalar `Int64` value;
- `JSONFloat`: a scalar `Float64` value;
- `JSONString`: a scalar string;
- `JSONBool`: a scalar boolean;
- `JSONArray`: a one-dimensional vector of any of the `JSON*` structures;
- `JSONSingleton`: a scalar singleton such as `NaN`, `+Inf` or `missing`;
- `JSONValue`: a typed value such as a `Int8`, a `Date` or a `Symbol`;
- `JSONDict`: a dictionary with `Symbol` keys and any `JSON*` structure as values.

Note that the above structures directly maps onto the basic type which are allowed in JSON, namely `null`, a number, a string, a boolean, a vector and a dictionary.  This is why the `TypedJSON` intermediate representation is guaranteed to be serialized and deserialized without loss of information.

More specifically, the `JSONSingleton`, `JSONValue` and `JSONDict` structures are all serialized as dictionaries with an additional entry representing the original data type.  Such type is stored as a string in JSON and as a Symbol within these structures. Upon reconstruction, the Julia type symbol is used to dispatch to the proper `reconstruct` method by wrapping it into a `Val` object (see examples below).

The following guidelines should be followed when implementing new `lower` and `reconstruct` methods:
- The `lower` method should accept a single Julia value and return an instance of one of the abore structures;
- The julia type symbol (required by the `JSONSingleton`, `JSONValue` and `JSONDict` constructors) should be the type name itself prepended by the module name where the data type is identified (e.g. `Dates.DateTime`);
- The corresponding `reconstruct` method should accept just two arguments:
  - a `::Val{Symbol("MODULE.TYPE")}` where `MODULE.TYPE` is the data type name;
  - a single dictionary containing the reconstructed entries for the data type.


## Examples

### Working with a custom structure

Consider the following user defined structure:
```julia
struct TestPerson
    name::String
    age::Int
    active::Bool
end
```
There is no need to define a `lower` method here, while the `reconstruct` method is as follows:
```julia
using TypedJSON
import TypedJSON: reconstruct
TypedJSON.reconstruct(::Val{Symbol("Main.TestPerson")}, dict) = TestPerson(values(dict)...)
```

The following code shows how to serialize and deserialize a `TestPerson` object:
```julia
p = TestPerson("Alice", 30, true)
TypedJSON.serialize("test.json", p)
show(TypedJSON.deserialize("test.json"))
```

## Working with DataFrames

We can serialize and deserialize `DataFrame`s by providing the following implementations for the `lower` and `reconstruct` methods:
```julia
using TypedJSON, DataFrames, DataStructures, Dates
import TypedJSON: lower, reconstruct

function TypedJSON.lower(df::DataFrame)
    dict = OrderedDict{Symbol, TypedJSON.JSONType}()
    for col_name in names(df)
        dict[Symbol(col_name)] = TypedJSON.lower(df[!, col_name])
    end
    return TypedJSON.JSONDict(:DataFrame, dict)
end

TypedJSON.reconstruct(::Val{:DataFrame}, dict) = DataFrame(dict)
```

The following code shows how to serialize and deserialize a `DataFrame` object:
```julia
df = DataFrame(
	A = [1, 2, 3],
	B = ["x", missing, "z"],
	C = [Date(2020,1,1), Date(2020,1,2), Date(2020,1,3)]
	)
TypedJSON.serialize("test.json.gz", df)
show(TypedJSON.deserialize("test.json.gz"))
```
Note that the filename used here has the `.gz` extension, enabling automatic use of GZip compression.



## Can my data be serialized?

Not all Julia types can be fed to `TypedJSON`, e.g. there is no way to serialize a `Function`, an `IO` or a `Ptr` object (see *"Caveats"* section below).  On the other hand, many common data types such as an `Int8`, a `Dict`, a `Vector{Union{Missing, String}}` or a `Matrix{Float64}` (with proper handling of `NaN` and `Inf` values) are all handled properly out of the box.   To support additional data types you should implement the corresponding `lower` and `reconstruct` methods.

To check whether a Julia object can be serialized/deserialized with `TypedJSON` use it as argument to the `TypedJSON.roundtrip` function.  Its return value is supposed to be as close as possible as the original value. E.g.
```julia
julia> TypedJSON.roundtrip([0 missing; "foo" π; Inf NaN; 1+2im nothing])
4×2 Matrix{Any}:
  0          missing
   "foo"    π
 Inf      NaN
 1+2im       nothing
```

This function also allows to inspect at intermediate steps between serialization and deserialization (se the help string for additional details).




## How do the "typed JSON" looks like?

You can inspect the generated JSON data with `TypedJSON.prettyprint_json`, e.g.:

```julia
julia> TypedJSON.prettyprint_json(TestPerson("Alice", 30, true))
{
    ":": "Main.TestPerson",
    "+": {
        "name": "Alice",
        "age": 30,
        "active": true
    }
}

julia> ypedJSON.prettyprint_json([0 missing; "foo" π; Inf NaN; 1+2im nothing])
{
    ":": "Array",
    "+": {
        "size": {
            ":": "Tuple",
            "": [
                4,
                2
            ]
        },
        "data": [
            0,
            "foo",
            {
                ":": "pInf"
            },
            {
                ":": "Complex",
                "+": {
                    "re": 1,
                    "im": 2
                }
            },
            {
                ":": "Missing"
            },
            {
                ":": "Irrational",
                "": "π"
            },
            {
                ":": "NaN"
            },
            null
        ]
    }
}
```


## Caveats


As anticipated, some data types such as `Function`, an `IO` or a `Ptr` objects can not be serialized.  Still, `TypedJSON` convert these values to `nothing` to avoid raising errors when a serialization is attempted.

> [!WARNING]
> In a few cases `TypedJSON` perform **silent** conversions to `nothing` for types which can not be serialized.  This is a deliberate choice motivated by the need to avoid a dedicated `lower()` method for all user defined structures containing non-serializable types (besides other fields which can be automatically serialized).  The `reconstruct()` method for such structures, however, is always needed hence the impossibility to deal with non-serializable objects will be made clear once deserialization is attempted.

Also note that `TypedJSON` is not able to deal with all possible data type combinations, it only aims to cover the simplest cases and leave the user to address the application specific details by adding methods to the `lower` and `reconstruct` functions.

One of the limitations of `TypedJSON` is that it is not always able to recover the parametric types. E.g. if you attempt to roundtrip a `Vector{AbstractFloat}` containing `Float64` you would obtain a `Vector{Float64}`:
```julia
julia> TypedJSON.roundtrip(Vector{AbstractFloat}([1., 2.]))
2-element Vector{Float64}:
 1.0
 2.0
```

It is however possible to address any specific case by adding dedicated `lower` and `reconstruct` methods, e.g.
```julia
import TypedJSON: lower, reconstruct
lower(v::Vector{AbstractFloat}) = TypedJSON.JSONValue(Symbol("Vector{AbstractFloat}"), TypedJSON.JSONArray(lower.(v)))
reconstruct(::Val{Symbol("Vector{AbstractFloat}")}, v) = convert(Vector{AbstractFloat}, v)
```
Now `Vector{AbstractFloat}` are handled properly:
```julia
julia> TypedJSON.roundtrip(Vector{AbstractFloat}([1., 2.]))
2-element Vector{AbstractFloat}:
 1.0
 2.0
```

> [!TIP]
> The only way to safely ensure data can be serialized and deserialized without loss of information is to check the return value of `TypedJSON.roundtrip`.


Finally, note that deserialization of JSON files from untrusted sources may lead to security issues (see [here](https://discourse.julialang.org/t/ann-typedjson-jl-a-julia-serialization-library-prioritizing-type-fidelity-human-readability-and-long-term-archival/134866/9)
