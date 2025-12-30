using Test
using Dates
using DataStructures
using DataFrames

using TypedJSON

import TypedJSON: lower, reconstruct

# 1. Custom Struct Setup
struct TestPerson
    name::String
    age::Int
    active::Bool
end
# Define reconstruct for TestPerson
# Note: The serializer uses "CurrentModule.Type", so we use @__MODULE__
function TypedJSON.reconstruct(::Val{Symbol("$(@__MODULE__).TestPerson")}, dict)
    return TestPerson(dict[:name], dict[:age], dict[:active])
end

# 2. DataFrame Setup (From previous conversation)
function TypedJSON.lower(df::DataFrame)
    dict = OrderedDict{Symbol, TypedJSON.JSONType}()
    for col_name in names(df)
        dict[Symbol(col_name)] = TypedJSON.lower(df[!, col_name])
    end
    return TypedJSON.JSONDict(:DataFrame, dict)
end

function TypedJSON.reconstruct(::Val{:DataFrame}, dict)
    return DataFrame(dict)
end

# ====================================================================
# TEST SUITE
# ====================================================================

@testset "TypedJSON test suite" begin

    # Helper function for round-trip testing
    # We use a temporary directory so we don't clutter the user's filesystem
    function roundtrip(data; compress=false)
        mktempdir() do dir
            ext = compress ? ".json.gz" : ".json"
            filepath = joinpath(dir, "test_file$ext")

            # Serialize
            TypedJSON.serialize(filepath, data, compress=compress)

            # Deserialize
            return TypedJSON.deserialize(filepath, compressed=compress)
        end
    end

    @testset "Primitives & Basic Types" begin
        @test roundtrip(100) == 100
        @test roundtrip(BigInt(100)) == BigInt(100)
        @test roundtrip(Int64(100)) == Int64(100)
        @test roundtrip(Int32(100)) == Int32(100)
        @test roundtrip(Int16(100)) == Int16(100)
        @test roundtrip(Int8( 100)) == Int8( 100)
        @test roundtrip(UInt64(100)) == UInt64(100)
        @test roundtrip(UInt32(100)) == UInt32(100)
        @test roundtrip(UInt16(100)) == UInt16(100)
        @test roundtrip(UInt8( 100)) == UInt8( 100)
        @test roundtrip(3.14159) == 3.14159
        @test roundtrip(BigFloat(π)) == BigFloat(π)
        @test roundtrip(Float64(π)) == Float64(π)
        @test roundtrip(Float32(π)) == Float32(π)
        @test roundtrip(Float16(π)) == Float16(π)

        @test roundtrip("Hello World") == "Hello World"
        @test roundtrip(true) == true
        @test roundtrip(false) == false
        @test roundtrip(nothing) === nothing
        @test roundtrip('a') == 'a'
        @test roundtrip(:my_symbol) == :my_symbol
    end

    @testset "Numerical Edge Cases" begin
        @test roundtrip(NaN) === NaN64
        @test roundtrip(Inf) === Inf
        @test roundtrip(-Inf) === -Inf
        @test isequal(roundtrip(BigFloat(NaN)), BigFloat(NaN))
        @test roundtrip(Float32(NaN))  ===  NaN32
        @test roundtrip(Float16(NaN))  ===  NaN16
        @test isequal(roundtrip(BigFloat(Inf)), BigFloat(Inf))
        @test roundtrip(Float32(Inf))  ===  Float32(Inf)
        @test roundtrip(Float16(Inf))  ===  Float16(Inf)
        @test isequal(roundtrip(BigFloat(-Inf)), BigFloat(-Inf))
        @test roundtrip(Float32(-Inf))  ===  Float32(-Inf)
        @test roundtrip(Float16(-Inf))  ===  Float16(-Inf)
    end

    @testset "Time & Date" begin
        d = Date(2023, 12, 25)
        dt = DateTime(2023, 12, 25, 14, 30, 0)

        @test roundtrip(d) == d
        @test roundtrip(dt) == dt
    end

    @testset "Collections" begin
        # Vectors
        vec_int = [1, 2, 3]
        vec_mix = Any[1, "two", 3.0]
        @test roundtrip(vec_int) == vec_int
        @test roundtrip(vec_mix) == vec_mix

        # Matrix
        mat_int = [1 2; 3 4]
        mat_mix = Any[1 missing; "two" 3.0]
        @test roundtrip(mat_int) == mat_int
        @test isequal(roundtrip(mat_mix), mat_mix)  # using isequal to deal with missing

        # Tuples
        tup = (1, "A", :sym)
        @test roundtrip(tup) == tup

        # NamedTuples
        nt = (a=1, b="bee", c=[1,2])
        @test roundtrip(nt) == nt

        # Dictionaries
        d = Dict(:a => 1, :b => 2)
        res = roundtrip(d)
        @test res[:a] == 1 && res[:b] == 2
        @test isa(res, Dict)

        d = OrderedDict(:a => 1, :b => 2)
        res = roundtrip(d)
        @test res[:a] == 1 && res[:b] == 2
        @test isa(res, OrderedDict)
    end

    @testset "Nested Structures" begin
        complex_nest = (
            meta = (id=1, status=:ok),
            data = [
                Dict(:val => 10.0, :time => Date(2023,1,1)),
                Dict(:val => NaN, :time => Date(2023,1,2))
            ]
        )

        res = roundtrip(complex_nest)

        @test res.meta.id == 1
        @test res.meta.status == :ok
        @test res.data[1][:val] == 10.0
        @test isequal(res.data[2][:val], NaN) # Check nested NaN
    end

    @testset "Custom Structs" begin
        p = TestPerson("Alice", 30, true)
        res = roundtrip(p)

        @test res isa TestPerson
        @test res.name == "Alice"
        @test res.age == 30
        @test res.active == true
    end

    @testset "DataFrames Extension" begin
        df = DataFrame(
            A = [1, 2, 3],
            B = ["x", "y", "z"],
            C = [Date(2020,1,1), Date(2020,1,2), Date(2020,1,3)]
        )

        res = roundtrip(df)

        @test res isa DataFrame
        @test res == df
        @test res.C[1] == Date(2020,1,1)
    end

    @testset "Compression (GZip)" begin
        data = rand(1000) # Large-ish array

        # 1. Implicit compression via filename extension
        mktempdir() do dir
            file = joinpath(dir, "test.json.gz")
            TypedJSON.serialize(file, data)
            loaded = TypedJSON.deserialize(file)
            @test loaded == data
        end

        # 2. Explicit flag usage
        mktempdir() do dir
            file = joinpath(dir, "test_force_gz") # No extension
            TypedJSON.serialize(file, data, compress=true)
            loaded = TypedJSON.deserialize(file, compressed=true)
            @test loaded == data
        end
    end

    @testset "Missing Values" begin
        @test isequal(roundtrip(missing), missing)

        # Missing inside vector
        v = [1, missing, 3]
        res = roundtrip(v)
        @test isequal(res, v)
    end
end
