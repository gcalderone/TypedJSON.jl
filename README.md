# TypedJSON.jl

**A Julia serialization library prioritizing type fidelity, human-readability, and long-term archival.**

`TypedJSON` allows you to serialize and deserialize Julia objects to/from JSON files. But Unlike other JSON libraries which convert data into generic strings or arrays, `TypedJSON` also stores metadata to allow proper reconstruction of data types.

The goal is similar to other serialization libraries such as the standard [Serialization](https://docs.julialang.org/en/v1/stdlib/Serialization/) or [JLD2](https://github.com/JuliaIO/JLD2.jl), but `TypedJSON` keeps the data in a human-readable form to ensure long term readability even if the definition of Julia structure change.

The following table shows a quick comparison between `TypedJSON` approach, and a few other solutions for data serialization:

| **Feature** | **Standard JSON** (e.g. [`JSON3.jl`](https://github.com/quinnj/JSON3.jl)) | **Binary blob** (e.g. [`JLD2.jl`](https://github.com/JuliaIO/JLD2.jl)) | **TypedJSON** |
| :---    | :---  | :--- | :--- |
| **Output Format**                          | Standard JSON           | Binary Blob                | Standard JSON (includes metadata besides data)    |
| **Human Readable**                         | ✅ Yes                  | ❌ No                      | ✅ Yes                                            |
| **Type Fidelity**                          | ❌ Low                  | ✅ High                    | ✅ High                                           |
| **Long-term Archival / schema evolution**  | ✅ Yes                  | ⚠️ Fragile                 | ✅ Yes (either automatically or via manual hooks) |
| **File storage efficiency**                | ❌ Low                  | ✅ High                    | ❌ Worst (also stores metadata). But it can explit Gzip compression |
| **Performance**                            | ❌ Low                  | ✅ High                    | ❌ Worst (maps data onto intermediate structures) |
| **Interoperability with other languages / libraries / applications** | ✅ Yes | ❌ No             | ✅ Yes (it may need additional efforts to neglect metadata) |
| **Require customization to handle custom data types**                | ❌ Yes | ✅ No             | ❌ Yes                                            |
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


## `TypedJSON` internals

`TypedJSON` fosters type fidelity by exploiting an intermediate representation of data types, sitting between the original Julia data type and the JSON data being written.  The advantage of such intermediate representation is that it is guaranteed to be identical to its original version upon deserialization.

The `TypedJSON` intermediate representation relies on the following structures:
- `JSONNull`: corresponding to the `nothing` singleton;
- `JSONInt`: a scalar `Int` value;
- `JSONFloat`: a scalar `Float64` value;
- `JSONString`: a scalar string;
- `JSONBool`: a scalar boolean;
- `JSONArray`: a one-dimensional vector of any of the `JSON*` structures;
- `JSONSingleton`: a scalar singleton such as `NaN`, `+Inf` or `missing`;
- `JSONValue`: a typed value such as a `Date` or a `Symbol`;
- `JSONDict`: a dictionary with `Symbol` keys and any `JSON*` structure as values.

The constructors of the `JSONSingleton`, `JSONValue` and `JSONDict` structures requires a `Symbol` to uniquely identify the the data type being serialized.  By convention, such symbol is simply the data type name, prepended by the module name where the data type is identified, e.g. `Core.Int32`, `Dates.DateTime`, etc.

The Julia types which directly map onto one of the above structures are already correctly handled by `TypedJSON`. For all other data types the following methods must be implemented:
- `lower`: to convert a generic Julia data type into one of the above `JSON*` structure;
- `reconstruct`: to convert a `JSON*` structure into the original Julia data type.

A new implementation for the `lower` method can be avoided if the structure fields map direrctly onto one of the `JSON*` structures.  A `reconstruct` method is, however, always needed.


## Working with custom data types

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
