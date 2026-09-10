using Test

include(joinpath(@__DIR__, "..", "CompareBench.jl"))
using .CompareBench

const AB = CompareBench.AB

@testset "comparison harness unit checks" begin
    @test CompareBench.require_baseline_profile!() === nothing
    definitions = CompareBench.tpch_sql_definitions()
    @test sort(collect(keys(definitions))) == collect(1:22)
    @test all(!isempty(strip(definitions[id])) for id in 1:22)

    config = AB.CConfig(warehouses=1, districts=1, customers=10, items=15, seed=20260903)
    first_fixture = AB.tpcc_data(; config=config)
    second_fixture = AB.tpcc_data(; config=config)
    @test sort(collect(keys(first_fixture))) == sort(collect(keys(AB.C_SCHEMA)))
    for table in keys(AB.C_SCHEMA)
        @test CompareBench.row_digest(first_fixture[table]) == CompareBench.row_digest(second_fixture[table])
    end
    @test length(first_fixture["warehouse"]) == 1
    @test length(first_fixture["district"]) == 1
    @test length(first_fixture["customer"]) == 10
    @test length(first_fixture["item"]) == 15

    action_signature(action) = (action.measured, action.kind, action.warehouse, action.district,
        action.customer, Tuple(action.items), Tuple(action.quantities), Tuple(action.supply),
        action.customer_warehouse, action.customer_district, action.customer_selector,
        action.amount, action.history_id, action.carrier, action.threshold)
    actions_a = CompareBench.tpcc_actions(config; transactions=20, warmup=5, seed=20260904)
    actions_b = CompareBench.tpcc_actions(config; transactions=20, warmup=5, seed=20260904)
    @test action_signature.(actions_a) == action_signature.(actions_b)
    @test length(actions_a) == 25
    @test count(action -> action.measured, actions_a) == 20
    @test Set(action.kind for action in actions_a) == Set((:NewOrder, :Payment, :OrderStatus, :Delivery, :StockLevel))
end

@testset "three-engine functional smoke" begin
    mktempdir() do temporary_root
        output = joinpath(temporary_root, "comparison")
        report = CompareBench.run_core(output; rows=8, batch=4, samples=1, warmup=0, seed=20260904, mode="verify", command=["compare-test"])
        @test report["status"] == "PASS"
        @test length(report["test_cases"]) == 18
        @test all(case["status"] == "PASS" for case in values(report["test_cases"]))
        @test isfile(joinpath(output, "report.json"))
    end
end
