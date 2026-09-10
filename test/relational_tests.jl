using Test
using Dates
using AiresDB
using AiresDB.Internal

@testset "Relational execution" begin
    @testset "Shape, projection, row isolation and trusted callbacks" begin
        relation = RelTable([:id, :name], [(1, "one"), (2, "two"), (3, nothing)])
        @test relation.rows[1].name == "one"
        @test length(relation) == 3
        @test Tuple.(collect(relation)) == [(1, "one"), (2, "two"), (3, nothing)]
        @test Tuple.(rproject(relation, [:name, :id]).rows) == [("one", 1), ("two", 2), (nothing, 3)]
        renamed = rrename(relation, [:id => :number])
        @test renamed[1].number == 1
        @test renamed.columns == [:number, :name]
        @test !haskey(renamed[1], :id)
        @test relation.columns == [:id, :name]
        @test Tuple.(rmap(relation, [:doubled], row -> (row.id * 2,)).rows) == [(2,), (4,), (6,)]
        @test Tuple.(rfilter(relation, row -> row.id > 1).rows) == [(2, "two"), (3, nothing)]
        @test isempty(rfilter(relation, row -> nothing))
        @test length(rfilter(row -> row.id == 1, relation)) == 1
        @test_throws AiresError rfilter(relation, row -> 1)
        @test_throws AiresError rproject(relation, [:absent])
        @test_throws AiresError RelTable([:x, :x], [(1, 2)])
        @test_throws AiresError RelTable([:x], [(1, 2)])
        @test_throws AiresError rrename(relation, [:id => :name])
        @test_throws AiresError rrename(relation, [:missing => :other])
        @test isempty(RelTable([:a, :b], Tuple[]))
        @test isempty(rmap(RelTable([:x], Tuple[]), [:z], row -> (row.x,)))
        @test query_result(rproject(relation, [:id])).rows == [[1], [2], [3]]
    end

    @testset "Exact values, SQL NULL logic and LIKE" begin
        @test sqlcmp(:eq, Money(100), Decimal("1.00")) === true
        @test sqlcmp(:eq, Int64(1), Decimal("1")) === true
        @test sqlcmp(:eq, -0.0, Int64(0)) === true
        @test sqlcmp(:lt, Money(100), Money(101)) === true
        @test sqlcmp(:ge, Decimal("1.0"), Decimal("1.01")) === false
        @test sqlcmp(:eq, Money(9_007_199_254_740_993), Money(9_007_199_254_740_992)) === false
        @test sqlcmp(:eq, nothing, nothing) === nothing
        @test_throws AiresError sqlcmp(:eq, true, 1)
        @test sqland(nothing, false) === false
        @test sqland(nothing, true) === nothing
        @test sqlor(nothing, true) === true
        @test sqlor(nothing, false) === nothing
        @test sqlnot(nothing) === nothing
        @test sqlnot(false) === true
        @test sqlin(1, [2, 1, nothing]) === true
        @test sqlin(1, [2, nothing]) === nothing
        @test sqlin(1, [2, 3]) === false
        @test sqlin(nothing, [1, 2]) === nothing
        @test sqllike("PROMO ANODIZED STEEL", "PROMO%")
        @test sqllike("á中\n", "___")
        @test sqllike("a%b_c", raw"a\%b\_c")
        @test sqllike("[.*]", "[.*]")
        @test !sqllike("x[.*]", "[.*]")
        @test sqllike(nothing, SqlLike("%")) === nothing
        @test SqlLike("%special%requests%")("some special new requests today")
        @test_throws AiresError SqlLike("trailing\\")
        @test radd(Money(10), Money(20)) == Money(30)
        @test rmul(Money(10), Int64(3)) == Money(30)
        @test sqlcmp(:eq, radd(typemax(Int64), Int64(1)), big(typemax(Int64)) // big(1) + 1) === true
        @test sqlcmp(:eq, rmul(typemax(Int64), Int64(2)), big(typemax(Int64)) // big(1) * 2) === true
        @test sqlcmp(:eq, radd(Money(typemax(Int128)), Money(1)), (big(typemax(Int128)) + 1) // big(100)) === true
        @test sqlcmp(:eq, rdiv(Money(100), Int64(3)), big(1) // big(3)) === true
        @test radd(nothing, Money(100)) === nothing
        @test_throws AiresError rdiv(1, 0)
    end

    @testset "Hash joins, residual predicates, NULL and duplicate keys" begin
        left = RelTable([:id, :value], [(1, "a"), (1, "b"), (2, "c"), (nothing, "d")])
        right = RelTable([:id, :value], [(1, 10), (1, 20), (3, 30), (nothing, 40)])
        inner = hashjoin(left, right; on=[:id => :id])
        @test inner.columns == [:id, :value, :id_right, :value_right]
        @test Tuple.(inner.rows) == [(1, "a", 1, 10), (1, "a", 1, 20), (1, "b", 1, 10), (1, "b", 1, 20)]
        @test length(hashjoin(left, right; on=[:id => :id], kind=:left)) == 6
        @test Tuple.(hashjoin(left, right; on=[:id => :id], kind=:semi).rows) == [(1, "a"), (1, "b")]
        @test Tuple.(hashjoin(left, right; on=[:id => :id], kind=:anti).rows) == [(2, "c"), (nothing, "d")]
        outer = hashjoin(left, right; on=[:id => :id], kind=:left, predicate=(a, b) -> false)
        @test length(outer) == 4
        @test all(row -> row.id_right === nothing && row.value_right === nothing, outer.rows)
        @test length(hashjoin(left, right; on=[:id => :id], kind=:anti, predicate=(a, b) -> nothing)) == 4
        @test length(hashjoin(left, right; on=Pair{Symbol,Symbol}[])) == 16
        @test_throws AiresError hashjoin(left, right; on=[:missing => :id])
        @test_throws AiresError hashjoin(left, right; on=[:id => :id], predicate=(a, b) -> 1)
        numeric_left = RelTable([:x], [(1,), (Money(100),), (Decimal("1.0"),), (nothing,)])
        numeric_right = RelTable([:y], [(Decimal("1"),), (nothing,)])
        @test length(hashjoin(numeric_left, numeric_right; on=[:x => :y])) == 3
        boolean = RelTable([:x], [(true,), (false,)])
        @test isempty(hashjoin(boolean, numeric_right; on=[:x => :y]))
        @test isempty(hashjoin(left, RelTable([:id], Tuple[]); on=[:id => :id]))
        @test length(hashjoin(left, RelTable([:id], Tuple[]); on=[:id => :id], kind=:left)) == 4
        collision = hashjoin(RelTable([:id, :id_right], [(1, 2)]), RelTable([:id], [(1,)]); on=[:id => :id])
        @test collision.columns == [:id, :id_right, :id_right_right]
    end

    @testset "Differential join audit against nested-loop reference" begin
        for trial in 1:36
            leftrows = [(mod(i + trial, 5) == 0 ? nothing : mod(i, 3), mod(i + trial, 2), i) for i in 1:mod(trial, 11)]
            rightrows = [(mod(i + trial, 4) == 0 ? nothing : mod(i, 3), mod(i, 2), i) for i in 1:mod(trial * 7, 13)]
            left = RelTable([:key, :part, :li], leftrows)
            right = RelTable([:key, :part, :ri], rightrows)
            residual = (a, b) -> mod(a.li + b.ri, 3) != 0
            for kind in (:inner, :left, :semi, :anti)
                expected = Tuple[]
                for lrow in left.rows
                    matched = [rrow for rrow in right.rows if lrow.key !== nothing && rrow.key !== nothing && lrow.key == rrow.key && lrow.part == rrow.part && residual(lrow, rrow)]
                    if kind === :semi
                        !isempty(matched) && push!(expected, Tuple(lrow))
                    elseif kind === :anti
                        isempty(matched) && push!(expected, Tuple(lrow))
                    elseif isempty(matched)
                        kind === :left && push!(expected, (Tuple(lrow)..., nothing, nothing, nothing))
                    else
                        append!(expected, [(Tuple(lrow)..., Tuple(rrow)...) for rrow in matched])
                    end
                end
                actual = hashjoin(left, right; on=[:key => :key, :part => :part], kind=kind, predicate=residual)
                @test Tuple.(actual.rows) == expected
            end
        end
    end

    @testset "Hash aggregation and scalar empty set semantics" begin
        input = RelTable([:group, :amount], [("a", Money(100)), ("a", Money(200)), ("a", nothing), (nothing, Money(400)), (nothing, nothing)])
        grouped = groupby(input, [:group], [:total => Sum(:amount), :n => Count(), :present => Count(:amount), :average => Avg(:amount), :lo => Min(:amount), :hi => Max(:amount), :distinct => CountDistinct(:amount)])
        @test length(grouped) == 2
        @test grouped[1].total == Money(300)
        @test grouped[1].n == 3
        @test grouped[1].present == 2
        @test grouped[1].distinct == 2
        @test sqlcmp(:eq, grouped[1].average, Money(150)) === true
        @test grouped[1].lo == Money(100)
        @test grouped[1].hi == Money(200)
        @test grouped[2].group === nothing
        @test grouped[2].total == Money(400)
        @test raggregate(input, Count()) == 5
        @test raggregate(input, Sum(row -> rmul(row.amount, Int64(2)))) == Money(1400)
        empty = RelTable([:x], Tuple[])
        scalar = groupby(empty, Symbol[], [:n => Count(), :present => Count(:x), :s => Sum(:x), :a => Avg(:x), :lo => Min(:x), :hi => Max(:x), :distinct => CountDistinct(:x)])
        @test Tuple(scalar[1]) == (0, 0, nothing, nothing, nothing, nothing, 0)
        @test isempty(groupby(empty, [:x], [:n => Count()]))
        @test raggregate(empty, Min(:x)) === nothing
        @test raggregate(empty, CountDistinct(:x)) == 0
        values = RelTable([:x], [(Int64(1),), (Decimal("1"),), (Money(100),), (nothing,), (nothing,)])
        @test length(groupby(values, [:x], [:n => Count()])) == 2
        @test raggregate(values, CountDistinct(:x)) == 1
        @test_throws AiresError groupby(values, [:x], [:x => Count()])
        @test_throws AiresError groupby(empty, Symbol[], [:n => Sum(:missing)])
        @test_throws AiresError raggregate(RelTable([:x], [("text",)]), Sum(:x))
    end

    @testset "Ordering, limits, distinct and union" begin
        input = RelTable([:a, :b], [(1, 3), (2, 2), (1, 2), (nothing, 9), (1, 2)])
        @test Tuple.(rsort(input, [:a => :asc, :b => :desc]).rows) == [(1, 3), (1, 2), (1, 2), (2, 2), (nothing, 9)]
        @test Tuple.(rsort(input, [:a => :desc, :b => :asc]; nulls=:first).rows) == [(nothing, 9), (2, 2), (1, 2), (1, 2), (1, 3)]
        @test Tuple.(rlimit(input, 2; offset=1).rows) == [(2, 2), (1, 2)]
        @test isempty(rlimit(input, 0))
        @test isempty(rlimit(input, 10; offset=100))
        @test length(rlimit(input, typemax(Int64); offset=1)) == 4
        @test_throws AiresError rlimit(input, -1)
        @test_throws AiresError rsort(input, [:a => :wrong])
        @test length(rdistinct(input)) == 4
        @test length(rdistinct(input; columns=[:a])) == 3
        @test length(runion(input, rrename(input, [:a => :c]); all=true)) == 10
        @test length(runion(input, rrename(input, [:a => :c]); all=false)) == 4
        exact = RelTable([:x], [(Int64(0),), (-0.0,), (Decimal("0.0"),), (nothing,), (nothing,)])
        @test length(rdistinct(exact)) == 2
        @test_throws AiresError runion(input, RelTable([:x], [(1,)]))
    end
end
