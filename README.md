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
- The `lower` method should accept a single Julia value and return an instance of one of the abovre structures;
- The julia type symbol (required by the `JSONSingleton`, `JSONValue` and `JSONDict` constructors) should be the the type name itself prepended by the module name where the data type is identified (e.g. `Dates.DateTime`);
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
Note that the filename used here has thre `.gz` extension, enabling automatic use of GZip compression.


## Can my data be serialized?

Not all Julia type can be fed to `TypedJSON`, e.g. there is no way to serialize a `Function`, an `IO` or `Ptr` object.

On the other hand, common objects such as an `Int8`, a `Dict`, a `Vector{Union{Missing, String}}` or a `Matrix{Float64}` (with proper handling of `NaN` and `Inf` values) are all handled properly out of the box.   To support additional data types you should implement the corresponding `lower` and `reconstruct` method.

To check whether a Julia object can be serialized/deserialized with `TypedJSON` use it as argument to the `TypedJSON.roundtrip` function.  This function also allows to inspect at intermediate steps between serialization and deserialization (sse the help string for additional details).  E.g.
```julia
julia> TypedJSON.roundtrip([0 missing; "foo" π; Inf NaN; 1+2im nothing])
4×2 Matrix{Any}:
  0          missing
   "foo"    π
 Inf      NaN
 1+2im       nothing
```
