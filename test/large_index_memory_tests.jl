module LargeIndexMemoryTests

using Test
using AiresDB
using AiresDB.Internal
const A = AiresDB

@testset "Large tables retain persistent rather than boxed logical indexes" begin
    count = A.LOGICAL_INDEX_ROW_LIMIT + 1
    columns = [
        A.ColumnDef("ID",:I,0,false,true,false,false),
        A.ColumnDef("OrderKey",:I,0,true,false,false,false),
    ]
    rows = A.Row[A.Cell[Int64(index),Int64(count-index+1)] for index in 1:count]
    ids = UInt128.(1:count)
    table = A.Table("Large",columns,rows,Dict{String,Int128}(),ids,zeros(UInt64,count),
        Dict(id=>index for (index,id) in enumerate(ids)),Dict{Tuple,Dict{Tuple,UInt128}}(),
        Dict{UInt128,Union{Nothing,A.Row}}(),UInt128[])
    A.build_indexes!(table)
    @test isempty(table.indexes)
    @test A.indexed_row(table,(Int64(1),))[1] == UInt128(1)
    @test A.indexed_row(table,(Int64(count),))[1] == UInt128(count)

    table.rows[end][2] = table.rows[1][2]
    @test_throws A.AiresError A.build_indexes!(table)
end

@testset "Single-row staging stays sparse" begin
    columns = [A.ColumnDef("ID",:I,0,false,true,false,false), A.ColumnDef("Value",:I,0,false,false,false,false)]
    base = A.Table("Sparse",columns,A.Row[A.Cell[Int64(1),Int64(10)],A.Cell[Int64(2),Int64(20)]],Dict{String,Int128}())
    staged = A.copy_table_for_mutation(base)
    A.set_row!(staged,2,A.Cell[Int64(2),Int64(21)])
    @test staged.rows === base.rows
    @test staged.row_stamps === base.row_stamps
    @test base.rows[2] == A.Cell[2,20]
    @test A.table_row(staged,2) == A.Cell[2,21]
    @test A.table_rows(staged)[2] == A.Cell[2,21]
end

@testset "Commit change ordering only depends on changed rows" begin
    columns = [A.ColumnDef("ID",:I,0,false,true,false,false), A.ColumnDef("Value",:I,0,false,false,false,false)]
    table = A.Table("Order",columns,A.Row[
        A.Cell[Int64(30),Int64(1)],
        A.Cell[Int64(10),Int64(2)],
        A.Cell[Int64(20),Int64(3)],
    ],Dict{String,Int128}())
    ids = copy(table.row_ids)
    A.set_row!(table,3,A.Cell[Int64(20),Int64(30)])
    A.set_row!(table,1,A.Cell[Int64(30),Int64(10)])
    A.append_row!(table,A.Cell[Int64(40),Int64(4)];id=UInt128(40))
    A.remove_rows!(table,[2])
    @test A.ordered_changes(table) == UInt128[ids[1],ids[3],40,ids[2]]
end

end
