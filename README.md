# TypedJSON.jl

**A Julia serialization library prioritizing type fidelity, human-readability, and long-term archival.**

`TypedJSON` allows you to serialize and deserialize Julia objects to/from JSON files. But unlike other JSON libraries which convert data into generic strings or arrays, `TypedJSON` also stores metadata to attempt a proper reconstruction of data types.

The goal is similar to other serialization libraries such as the standard [Serialization](https://docs.julialang.org/en/v1/stdlib/Serialization/) or [JLD2](https://github.com/JuliaIO/JLD2.jl), but `TypedJSON` keeps the data in a human-readable form to ensure long term readability even if the definition of Julia structures evolve in time (version drift).

The following table shows a quick comparison between `TypedJSON` approach and a few other solutions for data serialization:

| **Feature** | [`JSON3.jl`](https://github.com/quinnj/JSON3.jl) | [`JLD2.jl`](https://github.com/JuliaIO/JLD2.jl) | **TypedJSON** |
| :---    | :---  | :--- | :--- |
| **Output format**                                                    | Binary Blob  | Standard JSON   | Standard JSON (includes metadata besides data)    |
| **Human readable**                                                   | ❌ No        | ✅ Yes          | ✅ Yes                                            |
| **Type fidelity**                                                    | ✅ High      | ❌ Low          | ✅ High                                           |
| **Long-term archival / schema evolution**                            | ⚠️ Fragile   | ✅ Yes          | ✅ Yes (either automatically or via manual edits) |
| **File storage efficiency**                                          | ✅ High      | ❌ Low          | ❌ Low (high with GZip compression)               |
| **Performance**                                                      | ✅ High      | ❌ Low          | ❌ Low                                            |
| **Interoperability with other languages / libraries / applications** | ❌ No        | ✅ Yes          | ✅ Yes                                            |
| **Require new methods to handle custom data types**                  | ✅ No        | ❌ Yes          | ❌ Yes                                            |
---

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

`TypedJSON` fosters type fidelity by converting input data to an intermediate representation which can be serialized (deserialized) to (from) JSON format without loss of type information.  The conversion from the original Julia type to the intermediate representation is dubbed *lowering* and is performed via the `TypedJSON.lower` methods.  Typically there is need to define additional `lower` methods for custom types, although this is definitely possible.

The inverse conversion, from the intermediate representation to the original Julia type, is dubbed *reconstruction* and is performed via the `TypedJSON.reconstruct` methods. For user defined structs you need to define your own `reconstruct` method.

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

If you can convert, or *lower*, a Julia object into any of the above structures without loss of information, then the Julia object can be safely deserialized, or *reconstructed*, from JSON preserving the types.

The constructors of the `JSONSingleton`, `JSONValue` and `JSONDict` structures requires a `Symbol` to uniquely identify the the data type being serialized.  By convention, such symbol is simply the data type name prepended by the module name where the data type is identified, e.g. `Dates.DateTime`, etc.


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

We can serialize and deserialize `DataFrame`s by providing the following implementations for `lower` and `reconstruct`:
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
TypedJSON.serialize("test.json", df)
show(TypedJSON.deserialize("test.json"))
```


## Debug
