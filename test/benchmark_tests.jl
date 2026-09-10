using Test, AiresDB
using AiresDB.Internal
if !isdefined(Main,:AiresBench)
    include(joinpath(@__DIR__,"../benchmark/AiresBench.jl"))
end
const BBench=AiresBench

@testset "TPC-derived workload correctness" begin
    @testset "Exact DBGEN numeric conversion" begin
        @test BBench.parse_scaled_integer("123.45",2)==12345
        @test BBench.parse_scaled_integer("-0.06",2)==-6
        @test BBench.parse_scaled_integer("0.06",2)==6
        @test BBench.parse_scaled_integer("50.00",0)==50
        @test_throws ArgumentError BBench.parse_scaled_integer("1.001",2)
        @test_throws ArgumentError BBench.parse_scaled_integer("NaN",2)
        @test_throws InexactError BBench.parse_scaled_integer("9223372036854775808",0)
        # One full-width row per table verifies every .tbl field position and scale.
        mktempdir() do directory
            data=BBench.tpch_data(scale=0.0001,seed=99)
            tbl=joinpath(directory,"tbl");mkpath(tbl)
            for table in keys(BBench.H_SCHEMA)
                values=String[]
                for ((name,kind),value) in zip(BBench.H_SCHEMA[table],first(data[table]))
                    if name in BBench.H_SCALED_FIELDS
                        push!(values,string(value<0 ? "-" : "",div(abs(value),100),".",lpad(rem(abs(value),100),2,'0')))
                    else
                        push!(values,string(value))
                    end
                end
                write(joinpath(tbl,table*".tbl"),join(values,'|')*"|\n")
            end
            s=Session(joinpath(directory,"engine"));execute!(s,"Buat 'ImportTest' -:")
            counts=BBench.load_tpch_dbgen!(s,tbl)
            @test all(==(1),values(counts))
            for table in keys(BBench.H_SCHEMA)
                @test only(scan_rows(s,table))==first(data[table])
            end
            close(s)
            AiresDB._close_page_stores_under!(directory)
        end
    end
    @testset "Five TPC-C transaction types and application invariants" begin
        mktempdir() do directory
            s=Session(directory);execute!(s,"Buat 'CTest' -:")
            config=BBench.CConfig(warehouses=2,districts=2,customers=10,items=30,seed=771)
            counts=BBench.load_tpcc!(s;config)
            @test length(counts)==9
            @test counts["customer"]==40
            @test counts["stock"]==60
            @test all(values(BBench.tpcc_consistency(s;config)))

            # New-Order: local and remote stock; exact tax/discount total.
            district=BBench.c_get(s,"district",(1,1));warehouse=BBench.c_get(s,"warehouse",1);customer=BBench.c_get(s,"customer",(1,1,1))
            supply=[1,1,2,1,1];quantity=[1,2,3,4,5]
            before=[BBench.c_get(s,"stock",(supply[i],i)) for i in 1:5]
            result=BBench.transaction(s) do tx
                BBench.new_order!(tx,1,1,1,collect(1:5),quantity,supply)
            end
            @test result.order_id==11
            @test result.total_cents==big(result.subtotal_cents)*(10000-customer.c_discount)*(10000+warehouse.w_tax+district.d_tax)//big(100000000)
            @test BBench.c_get(s,"orders",(1,1,11)).o_all_local==0
            for i in 1:5
                current=BBench.c_get(s,"stock",(supply[i],i));old=before[i];q=quantity[i]
                @test current.s_quantity==(old.s_quantity>=q+10 ? old.s_quantity-q : old.s_quantity-q+91)
                @test current.s_ytd==old.s_ytd+q
                @test current.s_order_cnt==old.s_order_cnt+1
                @test current.s_remote_cnt==old.s_remote_cnt+(supply[i]!=1)
            end

            # The invalid last item occurs after earlier writes have been staged.
            before_all=Dict(t=>scan_rows(s,t) for t in keys(BBench.C_SCHEMA))
            @test_throws BBench.InvalidItem BBench.transaction(s) do tx
                BBench.new_order!(tx,1,1,1,[1,2,3,4,999],[1,1,1,1,1],[1,1,1,1,1])
            end
            @test all(scan_rows(s,t)==r for (t,r) in before_all)

            # Payment: lower middle by first name, remote customer, bad-credit data.
            BBench.transaction(s) do tx
                for (id,first) in ((1,"A"),(2,"B"),(3,"C"),(4,"D"))
                    BBench.c_update(tx,"customer",(2,2,id);c_last="MEDIAN",c_first=first,c_credit="BC")
                end
            end
            wbefore=BBench.c_get(s,"warehouse",1).w_ytd;dbefore=BBench.c_get(s,"district",(1,1)).d_ytd
            balance=BBench.c_get(s,"customer",(2,2,2)).c_balance
            result=BBench.transaction(s) do tx
                BBench.payment!(tx,1,1,2,2,"MEDIAN",12345;history_id=41)
            end
            @test result.customer_id==2
            @test result.balance_cents==balance-12345
            @test BBench.c_get(s,"warehouse",1).w_ytd==wbefore+12345
            @test BBench.c_get(s,"district",(1,1)).d_ytd==dbefore+12345
            @test startswith(BBench.c_get(s,"customer",(2,2,2)).c_data,"2 2 2 1 1 12345")
            @test BBench.c_get(s,"history",41).h_c_w_id==2

            # Order-Status reads the newest order with all its lines.
            result=BBench.transaction(s) do tx
                BBench.order_status(tx,1,1,1)
            end
            @test result.order.o_id==11
            @test length(result.lines)==5
            @test sum(x.ol_amount for x in result.lines)==BBench.c_get(s,"order_line",(1,1,11,1)).ol_amount+sum(BBench.c_get(s,"order_line",(1,1,11,n)).ol_amount for n in 2:5)

            # Delivery chooses the oldest pending order in every district.
            expected=Dict{Int,Tuple}()
            for d in 1:2
                o=BBench.c_get(s,"orders",(1,d,8));c=BBench.c_get(s,"customer",(1,d,o.o_c_id))
                amount=sum(BBench.c_get(s,"order_line",(1,d,8,n)).ol_amount for n in 1:o.o_ol_cnt)
                expected[d]=(o.o_c_id,c.c_balance+amount,c.c_delivery_cnt+1)
            end
            delivered=BBench.transaction(s) do tx
                BBench.delivery!(tx,1,7;districts=2)
            end
            @test delivered==[(1,8),(2,8)]
            for d in 1:2
                @test lookup(s,"new_order",(1,d,8))===nothing
                @test BBench.c_get(s,"orders",(1,d,8)).o_carrier_id==7
                id,balance,delivery_count=expected[d];c=BBench.c_get(s,"customer",(1,d,id))
                @test c.c_balance==balance
                @test c.c_delivery_cnt==delivery_count
                @test BBench.c_get(s,"order_line",(1,d,8,1)).ol_delivery_d!==nothing
            end

            # Stock-Level checks distinct item keys in the most recent20 orders.
            next=BBench.c_get(s,"district",(1,1)).d_next_o_id
            itemkeys=Set(x.ol_i_id for x in BBench.c_scan(s,"order_line") if x.ol_w_id==1&&x.ol_d_id==1&&next-20<=x.ol_o_id<next)
            expected=count(i->BBench.c_get(s,"stock",(1,i)).s_quantity<20,itemkeys)
            @test BBench.transaction(tx->BBench.stock_level(tx,1,1,20),s)==expected
            @test all(values(BBench.tpcc_consistency(s;config)))
            close(s)
            AiresDB._close_page_stores_under!(directory)
        end
    end

    @testset "All22 TPC-H plans versus independent SQL oracle" begin
        mktempdir() do directory
            s=Session(directory);execute!(s,"Buat 'HTest' -:")
            counts=BBench.load_tpch!(s;scale=0.0001,seed=20260903)
            @test length(counts)==8
            @test counts["nation"]==25
            @test counts["region"]==5
            for id in 1:22
                answer=BBench.tpch_query(s,id;scale=0.0001)
                @test answer isa RelTable
                # SF0.0001 means Q11's fraction is1, legitimately no qualifying part.
                id==11 ? (@test isempty(answer)) : (@test !isempty(answer))
            end
            data=joinpath(directory,"data");answers=joinpath(directory,"answers")
            BBench.export_tpch(s,data);BBench.export_answers(s,answers;scale=0.0001)
            python=get(ENV,"AIRESDB_PYTHON",joinpath(homedir(),".cache","codex-runtimes","codex-primary-runtime","dependencies","python","python.exe"))
            if !isfile(python)
                python=something(Sys.which("python3"),"")
            end
            if isempty(python) || !isfile(python)
                @warn "Set AIRESDB_PYTHON to run independent22-query SQL oracle"
                @test_skip false
            else
                oracle=joinpath(@__DIR__,"../benchmark/oracle.py")
                @test success(`$python $oracle $data $answers --scale 0.0001`)
            end
            close(s)
            AiresDB._close_page_stores_under!(directory)
        end
    end
end
