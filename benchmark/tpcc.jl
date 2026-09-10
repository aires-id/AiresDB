# TPC-C business transactions, using only the public AiresDB transaction/CRUD API.
# Integer monetary columns are cents; tax and discount columns are basis points.
const C_SCHEMA = Dict(
"warehouse"=>[("w_id","I"),("w_name","C(16)"),("w_street_1","C(24)"),("w_street_2","C(24)"),("w_city","C(24)"),("w_state","C(2)"),("w_zip","C(9)"),("w_tax","I"),("w_ytd","I")],
"district"=>[("d_w_id","I"),("d_id","I"),("d_name","C(16)"),("d_street_1","C(24)"),("d_street_2","C(24)"),("d_city","C(24)"),("d_state","C(2)"),("d_zip","C(9)"),("d_tax","I"),("d_ytd","I"),("d_next_o_id","I")],
"customer"=>[("c_w_id","I"),("c_d_id","I"),("c_id","I"),("c_first","C(16)"),("c_middle","C(2)"),("c_last","C(16)"),("c_street_1","C(24)"),("c_street_2","C(24)"),("c_city","C(24)"),("c_state","C(2)"),("c_zip","C(9)"),("c_phone","C(16)"),("c_since","C(24)"),("c_credit","C(2)"),("c_credit_lim","I"),("c_discount","I"),("c_balance","I"),("c_ytd_payment","I"),("c_payment_cnt","I"),("c_delivery_cnt","I"),("c_data","C(500)")],
"history"=>[("h_id","I"),("h_c_w_id","I"),("h_c_d_id","I"),("h_c_id","I"),("h_w_id","I"),("h_d_id","I"),("h_date","C(24)"),("h_amount","I"),("h_data","C(32)")],
"item"=>[("i_id","I"),("i_im_id","I"),("i_name","C(24)"),("i_price","I"),("i_data","C(50)")],
"stock"=>vcat([("s_w_id","I"),("s_i_id","I"),("s_quantity","I")],[("s_dist_$(lpad(i,2,'0'))","C(24)") for i in 1:10],[("s_ytd","I"),("s_order_cnt","I"),("s_remote_cnt","I"),("s_data","C(50)")]),
"orders"=>[("o_w_id","I"),("o_d_id","I"),("o_id","I"),("o_c_id","I"),("o_entry_d","C(24)"),("o_carrier_id","I"),("o_ol_cnt","I"),("o_all_local","I")],
"new_order"=>[("no_w_id","I"),("no_d_id","I"),("no_o_id","I")],
"order_line"=>[("ol_w_id","I"),("ol_d_id","I"),("ol_o_id","I"),("ol_number","I"),("ol_i_id","I"),("ol_supply_w_id","I"),("ol_delivery_d","C(24)"),("ol_quantity","I"),("ol_amount","I"),("ol_dist_info","C(24)")])
const C_KEYS = Dict("warehouse"=>["w_id"],"district"=>["d_w_id","d_id"],"customer"=>["c_w_id","c_d_id","c_id"],"history"=>["h_id"],"item"=>["i_id"],"stock"=>["s_w_id","s_i_id"],"orders"=>["o_w_id","o_d_id","o_id"],"new_order"=>["no_w_id","no_d_id","no_o_id"],"order_line"=>["ol_w_id","ol_d_id","ol_o_id","ol_number"])
const C_NAMES = Dict(k=>Tuple(Symbol.(first.(v))) for (k,v) in C_SCHEMA)
const C_LAST = ["BAR","OUGHT","ABLE","PRI","PRES","ESE","ANTI","CALLY","ATION","EING"]
last_name(i)=join(C_LAST[d+1] for d in (div(i,100),div(i,10)%10,i%10))
c_named(table,row)=NamedTuple{C_NAMES[table]}(Tuple(row))
function c_get(s,table,key)
    row=lookup(s,table,key)
    row===nothing && error("Missing $table key $key")
    c_named(table,row)
end
c_scan(s,table)=[c_named(table,r) for r in scan_rows(s,table)]
c_update(s,t,k;kwargs...)=update_key!(s,t,k,Dict{String,Any}(String(k)=>v for (k,v) in kwargs))
c_insert(s,t,values)=bulk_insert!(s,t,[values])

Base.@kwdef struct CConfig
    warehouses::Int=1
    districts::Int=10
    customers::Int=100
    items::Int=1000
    seed::Int=20260903
end

"""Build the deterministic TPC-C-derived fixture without touching an engine.

The comparison runner uses this exact fixture for AiresDB, SQLite, and DuckDB,
so data generation is never included in just one backend's load measurement.
"""
function tpcc_data(; config=CConfig())
    c=config
    c.warehouses>=1 || error("at least one warehouse required")
    1<=c.districts<=10 || error("districts must be 1..10")
    c.items>=15 || error("at least 15 items required")
    c.customers>=10 || error("at least 10 customers required")
    rng=MersenneTwister(c.seed)
    data=Dict(t=>Vector{Any}[] for t in keys(C_SCHEMA))
    stamp="2026-01-01T00:00:00"
    for i in 1:c.items
        push!(data["item"],Any[i,rand(rng,1:10000),"Item$i",rand(rng,100:10000),rand(rng)<0.1 ? "ORIGINAL data" : "generic data"])
    end
    hid=0
    for w in 1:c.warehouses
        push!(data["warehouse"],Any[w,"Warehouse$w","Street1","Street2","City","CA","123456789",rand(rng,0:2000),c.districts*c.customers*1000])
        for i in 1:c.items
            push!(data["stock"],Any[w,i,rand(rng,10:100),["district $(lpad(d,2,'0')) information" for d in 1:10]...,0,0,0,rand(rng)<0.1 ? "ORIGINAL stock" : "stock data"])
        end
        for d in 1:c.districts
            push!(data["district"],Any[w,d,"District$d","Street1","Street2","City","CA","123456789",rand(rng,0:2000),c.customers*1000,c.customers+1])
            customers=randperm(rng,c.customers)
            for id in 1:c.customers
                push!(data["customer"],Any[w,d,id,"First$(lpad(id,6,'0'))","OE",last_name((id-1)%1000),"Street1","Street2","City","CA","123456789","1234567890123456",stamp,rand(rng)<0.1 ? "BC" : "GC",5000000,rand(rng,0:5000),-1000,1000,1,0,"customer data"])
                hid+=1
                push!(data["history"],Any[hid,w,d,id,w,d,stamp,1000,"Warehouse$w    District$d"])
                delivered=id<=floor(Int,0.7c.customers)
                count=rand(rng,5:15)
                push!(data["orders"],Any[w,d,id,customers[id],stamp,delivered ? rand(rng,1:10) : nothing,count,1])
                delivered || push!(data["new_order"],Any[w,d,id])
                for number in 1:count
                    push!(data["order_line"],Any[w,d,id,number,rand(rng,1:c.items),w,delivered ? stamp : nothing,5,delivered ? 0 : rand(rng,1:999999),"initial district info"])
                end
            end
        end
    end
    data
end

function load_tpcc!(s; config=CConfig())
    data=tpcc_data(;config)
    for table in sort(collect(keys(C_SCHEMA)))
        create_schema!(s,table,C_SCHEMA[table],C_KEYS[table])
    end
    counts=Dict{String,Int}()
    for table in sort(collect(keys(data)))
        load_rows!(s,table,data[table]);counts[table]=length(data[table]);empty!(data[table])
    end
    counts
end

struct InvalidItem <: Exception
    item::Int
end

"Execute New-Order inside an already open transaction. Missing final item must roll back the transaction."
function new_order!(s,w,d,cid,items,quantities,supply; stamp="2026-09-03T00:00:00")
    5<=length(items)<=15 || error("NewOrder needs 5..15 lines")
    length(items)==length(quantities)==length(supply) || error("line array mismatch")
    district=c_get(s,"district",(w,d)); customer=c_get(s,"customer",(w,d,cid)); warehouse=c_get(s,"warehouse",w)
    oid=district.d_next_o_id
    c_update(s,"district",(w,d);d_next_o_id=oid+1)
    c_insert(s,"orders",Any[w,d,oid,cid,stamp,nothing,length(items),all(==(w),supply) ? 1 : 0])
    c_insert(s,"new_order",Any[w,d,oid])
    subtotal=0; brands=String[]
    for n in eachindex(items)
        itemrow=lookup(s,"item",items[n]); itemrow===nothing && throw(InvalidItem(items[n]))
        item=c_named("item",itemrow); stock=c_get(s,"stock",(supply[n],items[n])); q=quantities[n]
        1<=q<=10 || error("quantity outside 1..10")
        quantity=stock.s_quantity>=q+10 ? stock.s_quantity-q : stock.s_quantity-q+91
        c_update(s,"stock",(supply[n],items[n]);s_quantity=quantity,s_ytd=stock.s_ytd+q,s_order_cnt=stock.s_order_cnt+1,s_remote_cnt=stock.s_remote_cnt+(supply[n]!=w))
        amount=q*item.i_price; subtotal+=amount
        dist=getproperty(stock,Symbol("s_dist_$(lpad(d,2,'0'))"))
        c_insert(s,"order_line",Any[w,d,oid,n,items[n],supply[n],nothing,q,amount,dist])
        push!(brands,occursin("ORIGINAL",item.i_data)&&occursin("ORIGINAL",stock.s_data) ? "B" : "G")
    end
    # Exact rational cents, preserving the tax/discount expression without float rounding.
    total=BigInt(subtotal)*(10000-customer.c_discount)*(10000+warehouse.w_tax+district.d_tax)//big(100000000)
    (order_id=oid,subtotal_cents=subtotal,total_cents=total,brands=brands)
end

function select_customer(s,w,d,id_or_last)
    id_or_last isa Integer && return c_get(s,"customer",(w,d,id_or_last))
    candidates=sort(filter(c->c.c_w_id==w&&c.c_d_id==d&&c.c_last==id_or_last,c_scan(s,"customer"));by=c->c.c_first)
    isempty(candidates) && error("No matching customer")
    candidates[cld(length(candidates),2)]
end

function payment!(s,w,d,cw,cd,id_or_last,amount; history_id,stamp="2026-09-03T00:00:00")
    100<=amount<=500000 || error("Payment outside 1..5000 currency units")
    warehouse=c_get(s,"warehouse",w); district=c_get(s,"district",(w,d)); customer=select_customer(s,cw,cd,id_or_last)
    c_update(s,"warehouse",w;w_ytd=warehouse.w_ytd+amount)
    c_update(s,"district",(w,d);d_ytd=district.d_ytd+amount)
    updates=Dict{String,Any}("c_balance"=>customer.c_balance-amount,"c_ytd_payment"=>customer.c_ytd_payment+amount,"c_payment_cnt"=>customer.c_payment_cnt+1)
    if customer.c_credit=="BC"
        updates["c_data"]=first("$(customer.c_id) $cd $cw $d $w $amount | "*customer.c_data,500)
    end
    update_key!(s,"customer",(cw,cd,customer.c_id),updates)
    c_insert(s,"history",Any[history_id,cw,cd,customer.c_id,w,d,stamp,amount,first(warehouse.w_name*"    "*district.d_name,24)])
    (customer_id=customer.c_id,balance_cents=customer.c_balance-amount)
end

function order_status(s,w,d,id_or_last)
    c=select_customer(s,w,d,id_or_last)
    orders=filter(o->o.o_w_id==w&&o.o_d_id==d&&o.o_c_id==c.c_id,c_scan(s,"orders"))
    isempty(orders) && return (customer=c,order=nothing,lines=NamedTuple[])
    order=orders[argmax(getproperty.(orders,:o_id))]
    lines=[c_get(s,"order_line",(w,d,order.o_id,n)) for n in 1:order.o_ol_cnt]
    (customer=c,order=order,lines=lines)
end

function delivery!(s,w,carrier; districts=10,stamp="2026-09-03T00:00:00")
    pending=filter(no->no.no_w_id==w,c_scan(s,"new_order")); delivered=Tuple{Int,Int}[]
    for d in 1:districts
        orders=filter(no->no.no_d_id==d,pending);isempty(orders)&&continue
        oid=minimum(no.no_o_id for no in orders)
        delete_key!(s,"new_order",(w,d,oid));order=c_get(s,"orders",(w,d,oid))
        c_update(s,"orders",(w,d,oid);o_carrier_id=carrier)
        amount=0
        for n in 1:order.o_ol_cnt
            line=c_get(s,"order_line",(w,d,oid,n));amount+=line.ol_amount
            c_update(s,"order_line",(w,d,oid,n);ol_delivery_d=stamp)
        end
        c=c_get(s,"customer",(w,d,order.o_c_id))
        c_update(s,"customer",(w,d,c.c_id);c_balance=c.c_balance+amount,c_delivery_cnt=c.c_delivery_cnt+1)
        push!(delivered,(d,oid))
    end
    delivered
end

function stock_level(s,w,d,threshold)
    next=c_get(s,"district",(w,d)).d_next_o_id; items=Set{Int}()
    for oid in max(1,next-20):next-1
        order=c_get(s,"orders",(w,d,oid))
        for n in 1:order.o_ol_cnt
            push!(items,c_get(s,"order_line",(w,d,oid,n)).ol_i_id)
        end
    end
    count(i->c_get(s,"stock",(w,i)).s_quantity<threshold,items)
end

"Application consistency checks over committed public snapshot scans."
function tpcc_consistency(s; config=CConfig())
    snapshot(s) do snap
        w=c_scan(snap,"warehouse");d=c_scan(snap,"district");o=c_scan(snap,"orders");no=c_scan(snap,"new_order");ol=c_scan(snap,"order_line");c=c_scan(snap,"customer");h=c_scan(snap,"history")
        checks=Dict{String,Bool}()
        checks["warehouse_ytd_equals_district_sum"]=all(x.w_ytd==sum(y.d_ytd for y in d if y.d_w_id==x.w_id) for x in w)
        checks["district_next_order"]=all(x.d_next_o_id==maximum(y.o_id for y in o if y.o_w_id==x.d_w_id&&y.o_d_id==x.d_id)+1 for x in d)
        orderindex=Dict((x.o_w_id,x.o_d_id,x.o_id)=>x for x in o)
        counts=Dict{Tuple,Int}();deliveredsums=Dict{Tuple,Int}()
        for line in ol
            key=(line.ol_w_id,line.ol_d_id,line.ol_o_id);counts[key]=get(counts,key,0)+1
            order=orderindex[key]
            if line.ol_delivery_d!==nothing
                ck=(line.ol_w_id,line.ol_d_id,order.o_c_id);deliveredsums[ck]=get(deliveredsums,ck,0)+line.ol_amount
            end
        end
        checks["order_line_counts"]=all(get(counts,k,0)==x.o_ol_cnt for (k,x) in orderindex)
        checks["new_orders_reference_undelivered_orders"]=all(haskey(orderindex,(x.no_w_id,x.no_d_id,x.no_o_id))&&orderindex[(x.no_w_id,x.no_d_id,x.no_o_id)].o_carrier_id===nothing for x in no)
        payments=Dict{Tuple,Int}()
        for x in h
            key=(x.h_c_w_id,x.h_c_d_id,x.h_c_id);payments[key]=get(payments,key,0)+x.h_amount
        end
        checks["customer_balance_matches_history_and_deliveries"]=all(x.c_balance==get(deliveredsums,(x.c_w_id,x.c_d_id,x.c_id),0)-get(payments,(x.c_w_id,x.c_d_id,x.c_id),0) for x in c)
        checks["customer_ytd_matches_history"]=all(x.c_ytd_payment==get(payments,(x.c_w_id,x.c_d_id,x.c_id),0) for x in c)
        checks
    end
end

function run_tpcc(s; config=CConfig(),transactions=500,warmup=25,seed=config.seed+1)
    transactions>0 || error("transactions must be positive")
    warmup>=0 || error("warmup must be nonnegative")
    rng=MersenneTwister(seed);latencies=Dict(k=>Int[] for k in ("NewOrder","Payment","OrderStatus","Delivery","StockLevel"))
    counters=Dict("commits"=>0,"expected_rollbacks"=>0,"errors"=>0,"retries"=>0)
    history_id=config.warehouses*config.districts*config.customers
    started=time_ns()
    mix=vcat(fill("NewOrder",45),fill("Payment",43),fill("OrderStatus",4),fill("Delivery",4),fill("StockLevel",4))
    warmtypes=["NewOrder","Payment","OrderStatus","Delivery","StockLevel"]
    for iteration in 1:warmup+transactions
        iteration==warmup+1 && (started=time_ns())
        # A shuffled 100-transaction block preserves exact 45/43/4/4/4 long-run mix.
        slot=mod1(iteration-warmup,100)
        iteration>warmup && slot==1 && shuffle!(rng,mix)
        kind=iteration<=warmup ? warmtypes[mod1(iteration,5)] : mix[slot]
        w=rand(rng,1:config.warehouses);d=rand(rng,1:config.districts);cid=rand(rng,1:config.customers)
        kwargs=nothing
        if kind=="NewOrder"
            n=rand(rng,5:15);items=rand(rng,1:config.items,n);quantities=rand(rng,1:10,n);supply=fill(w,n)
            if config.warehouses>1
                for j in 1:n
                    rand(rng)<0.01 && (supply[j]=rand(rng,filter(!=(w),collect(1:config.warehouses))))
                end
            end
            rand(rng)<0.01 && (items[end]=config.items+1)
            kwargs=(items,quantities,supply)
        elseif kind=="Payment"
            history_id+=1;cw=w;cd=d
            if config.warehouses>1 && rand(rng)<0.15
                cw=rand(rng,filter(!=(w),collect(1:config.warehouses)));cd=rand(rng,1:config.districts)
            end
            # Warm both dispatch/query shapes before measurement. Random
            # warmup could miss the String or Int customer selector and charge
            # Julia compilation to one of the four measured OrderStatus calls.
            warm_round=div(iteration-1,5)
            id=iteration<=warmup ? (iseven(warm_round) ? cid : last_name((cid-1)%1000)) :
                (rand(rng)<0.6 ? last_name((cid-1)%1000) : cid)
            kwargs=(cw,cd,id,rand(rng,100:500000),history_id)
        elseif kind=="OrderStatus"
            warm_round=div(iteration-1,5)
            kwargs=iteration<=warmup ? (iseven(warm_round) ? cid : last_name((cid-1)%1000)) :
                (rand(rng)<0.6 ? last_name((cid-1)%1000) : cid)
        end
        t=time_ns();committed=false;expected=false;retry_count=0
        while true
            try
                transaction(s) do tx
                    if kind=="NewOrder"
                        new_order!(tx,w,d,cid,kwargs...)
                    elseif kind=="Payment"
                        payment!(tx,w,d,kwargs[1:4]...;history_id=kwargs[5])
                    elseif kind=="OrderStatus"
                        order_status(tx,w,d,kwargs)
                    elseif kind=="Delivery"
                        delivery!(tx,w,rand(rng,1:10);districts=config.districts)
                    else
                        stock_level(tx,w,d,rand(rng,10:20))
                    end
                end
                committed=true;break
            catch e
                if e isa InvalidItem
                    expected=true;break
                elseif e isa AiresError && occursin("Conflict",e.category) && retry_count<3
                    retry_count+=1;continue
                else
                    iteration>warmup && (counters["errors"]+=1)
                    rethrow()
                end
            end
        end
        if iteration>warmup
            push!(latencies[kind],time_ns()-t)
            counters["commits"]+=committed;counters["expected_rollbacks"]+=expected;counters["retries"]+=retry_count
        end
    end
    wall=(time_ns()-started)/1e9
    checks=tpcc_consistency(s;config)
    all(values(checks)) || error("TPC-C consistency failure: $checks")
    summaries=Dict(k=>merge(latency_summary(v),Dict("mix_operations_per_second"=>length(v)/wall)) for (k,v) in latencies)
    Dict("notice"=>BENCHMARK_NOTICE,"transactions"=>transactions,"warmup_transactions"=>warmup,"seed"=>seed,
      "warehouses"=>config.warehouses,"districts_per_warehouse"=>config.districts,"customers_per_district"=>config.customers,"items"=>config.items,
      "wall_seconds"=>wall,"transactions_per_second"=>transactions/wall,"counters"=>counters,"consistency"=>checks,
      "latency"=>summaries)
end
