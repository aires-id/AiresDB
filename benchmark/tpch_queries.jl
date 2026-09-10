# All22 query families: ordinary relational plans over the public engine API.
# Fixed validation-style parameters are disclosed; no data/result cache is used.
# Prices are cents; l_discount/l_tax are integer percentages in these data files.
hrel(s,t)=relation(s,t)
hj(a,b,x,y;kwargs...)=hashjoin(a,b;on=[x=>y],kwargs...)
rev(r)=r.l_extendedprice*(100-r.l_discount)
hdiv(a,b)=a===nothing || b===nothing || b==0 ? nothing : BigInt(a)//BigInt(b)
hscalar(name,value)=RelTable([name],[(value,)])
hsum(r,f)=raggregate(r,Sum(f))
hy(r)=parse(Int,r.o_orderdate[1:4])
function hq1(s;scale=0.001)
    l=rfilter(hrel(s,"lineitem"),r->r.l_shipdate<="1998-09-02")
    g=groupby(l,[:l_returnflag,:l_linestatus],[:sum_qty=>Sum(:l_quantity),:sum_base_price=>Sum(:l_extendedprice),:sum_disc_price=>Sum(rev),:sum_charge=>Sum(r->rev(r)*(100+r.l_tax)),:avg_qty=>Avg(:l_quantity),:avg_price=>Avg(:l_extendedprice),:avg_disc=>Avg(:l_discount),:count_order=>Count()])
    rsort(rmap(g,g.columns,r->(r.l_returnflag,r.l_linestatus,r.sum_qty,hdiv(r.sum_base_price,100),hdiv(r.sum_disc_price,10000),hdiv(r.sum_charge,1000000),r.avg_qty,rdiv(r.avg_price,100),rdiv(r.avg_disc,100),r.count_order)),[:l_returnflag=>:asc,:l_linestatus=>:asc])
end
function hq2(s;scale=0.001)
    p=rfilter(hrel(s,"part"),r->r.p_size==15&&endswith(r.p_type,"BRASS"))
    n=hj(hrel(s,"nation"),rfilter(hrel(s,"region"),r->r.r_name=="EUROPE"),:n_regionkey,:r_regionkey)
    su=hj(hrel(s,"supplier"),n,:s_nationkey,:n_nationkey)
    ps=hj(hj(hrel(s,"partsupp"),p,:ps_partkey,:p_partkey),su,:ps_suppkey,:s_suppkey)
    minima=groupby(ps,[:ps_partkey],[:minimum_cost=>Min(:ps_supplycost)])
    winners=rfilter(hj(ps,minima,:ps_partkey,:ps_partkey),r->r.ps_supplycost==r.minimum_cost)
    a=rmap(winners,[:s_acctbal,:s_name,:n_name,:p_partkey,:p_mfgr,:s_address,:s_phone,:s_comment],r->(hdiv(r.s_acctbal,100),r.s_name,r.n_name,r.p_partkey,r.p_mfgr,r.s_address,r.s_phone,r.s_comment))
    rlimit(rsort(a,[:s_acctbal=>:desc,:n_name=>:asc,:s_name=>:asc,:p_partkey=>:asc]),100)
end
function hq3(s;scale=0.001)
    c=rfilter(hrel(s,"customer"),r->r.c_mktsegment=="BUILDING")
    o=hj(rfilter(hrel(s,"orders"),r->r.o_orderdate<"1995-03-15"),c,:o_custkey,:c_custkey)
    l=hj(rfilter(hrel(s,"lineitem"),r->r.l_shipdate>"1995-03-15"),o,:l_orderkey,:o_orderkey)
    g=groupby(l,[:l_orderkey,:o_orderdate,:o_shippriority],[:revenue=>Sum(rev)])
    a=rmap(g,[:l_orderkey,:revenue,:o_orderdate,:o_shippriority],r->(r.l_orderkey,hdiv(r.revenue,10000),r.o_orderdate,r.o_shippriority))
    rlimit(rsort(a,[:revenue=>:desc,:o_orderdate=>:asc]),10)
end
function hq4(s;scale=0.001)
    o=rfilter(hrel(s,"orders"),r->"1993-07-01"<=r.o_orderdate<"1993-10-01")
    l=rfilter(hrel(s,"lineitem"),r->r.l_commitdate<r.l_receiptdate)
    g=groupby(hj(o,l,:o_orderkey,:l_orderkey;kind=:semi),[:o_orderpriority],[:order_count=>Count()])
    rsort(g,[:o_orderpriority=>:asc])
end
function hq5(s;scale=0.001)
    n=hj(hrel(s,"nation"),rfilter(hrel(s,"region"),r->r.r_name=="ASIA"),:n_regionkey,:r_regionkey)
    c=hj(hrel(s,"customer"),n,:c_nationkey,:n_nationkey)
    o=hj(rfilter(hrel(s,"orders"),r->"1994-01-01"<=r.o_orderdate<"1995-01-01"),c,:o_custkey,:c_custkey)
    l=hj(hj(hrel(s,"lineitem"),o,:l_orderkey,:o_orderkey),hrel(s,"supplier"),:l_suppkey,:s_suppkey)
    g=groupby(rfilter(l,r->r.s_nationkey==r.c_nationkey),[:n_name],[:revenue=>Sum(rev)])
    rsort(rmap(g,g.columns,r->(r.n_name,hdiv(r.revenue,10000))),[:revenue=>:desc])
end
function hq6(s;scale=0.001)
    l=rfilter(hrel(s,"lineitem"),r->"1994-01-01"<=r.l_shipdate<"1995-01-01"&&5<=r.l_discount<=7&&r.l_quantity<24)
    hscalar(:revenue,hdiv(hsum(l,r->r.l_extendedprice*r.l_discount),10000))
end
function hq7(s;scale=0.001)
    nations=rfilter(hrel(s,"nation"),r->r.n_name in ("FRANCE","GERMANY"))
    su=hj(hrel(s,"supplier"),rmap(nations,[:sn_key,:supp_nation],r->(r.n_nationkey,r.n_name)),:s_nationkey,:sn_key)
    c=hj(hrel(s,"customer"),rmap(nations,[:cn_key,:cust_nation],r->(r.n_nationkey,r.n_name)),:c_nationkey,:cn_key)
    o=hj(hrel(s,"orders"),c,:o_custkey,:c_custkey)
    l=hj(hj(rfilter(hrel(s,"lineitem"),r->"1995-01-01"<=r.l_shipdate<="1996-12-31"),su,:l_suppkey,:s_suppkey),o,:l_orderkey,:o_orderkey)
    x=rmap(rfilter(l,r->r.supp_nation!=r.cust_nation),[:supp_nation,:cust_nation,:l_year,:volume],r->(r.supp_nation,r.cust_nation,parse(Int,r.l_shipdate[1:4]),rev(r)))
    g=groupby(x,[:supp_nation,:cust_nation,:l_year],[:revenue=>Sum(:volume)])
    rsort(rmap(g,g.columns,r->(r.supp_nation,r.cust_nation,r.l_year,hdiv(r.revenue,10000))),[:supp_nation=>:asc,:cust_nation=>:asc,:l_year=>:asc])
end
function hq8(s;scale=0.001)
    n=hj(hrel(s,"nation"),rfilter(hrel(s,"region"),r->r.r_name=="AMERICA"),:n_regionkey,:r_regionkey)
    c=hj(hrel(s,"customer"),n,:c_nationkey,:n_nationkey)
    o=hj(rfilter(hrel(s,"orders"),r->"1995-01-01"<=r.o_orderdate<="1996-12-31"),c,:o_custkey,:c_custkey)
    su=hj(hrel(s,"supplier"),rmap(hrel(s,"nation"),[:sn_key,:supp_nation],r->(r.n_nationkey,r.n_name)),:s_nationkey,:sn_key)
    l=hj(hj(hj(hrel(s,"lineitem"),rfilter(hrel(s,"part"),r->r.p_type=="ECONOMY ANODIZED STEEL"),:l_partkey,:p_partkey),su,:l_suppkey,:s_suppkey),o,:l_orderkey,:o_orderkey)
    x=rmap(l,[:o_year,:volume,:brazil],r->(hy(r),rev(r),r.supp_nation=="BRAZIL" ? rev(r) : 0))
    g=groupby(x,[:o_year],[:volume=>Sum(:volume),:brazil=>Sum(:brazil)])
    rsort(rmap(g,[:o_year,:mkt_share],r->(r.o_year,hdiv(r.brazil,r.volume))),[:o_year=>:asc])
end
function hq9(s;scale=0.001)
    l=hj(hrel(s,"lineitem"),rfilter(hrel(s,"part"),r->occursin("green",r.p_name)),:l_partkey,:p_partkey)
    ps=hashjoin(l,hrel(s,"partsupp");on=[:l_partkey=>:ps_partkey,:l_suppkey=>:ps_suppkey])
    su=hj(hrel(s,"supplier"),hrel(s,"nation"),:s_nationkey,:n_nationkey)
    x=hj(hj(ps,su,:l_suppkey,:s_suppkey),hrel(s,"orders"),:l_orderkey,:o_orderkey)
    a=rmap(x,[:nation,:o_year,:amount],r->(r.n_name,hy(r),rev(r)-r.ps_supplycost*r.l_quantity*100))
    g=groupby(a,[:nation,:o_year],[:sum_profit=>Sum(:amount)])
    rsort(rmap(g,g.columns,r->(r.nation,r.o_year,hdiv(r.sum_profit,10000))),[:nation=>:asc,:o_year=>:desc])
end
function hq10(s;scale=0.001)
    c=hj(hrel(s,"customer"),hrel(s,"nation"),:c_nationkey,:n_nationkey)
    o=hj(rfilter(hrel(s,"orders"),r->"1993-10-01"<=r.o_orderdate<"1994-01-01"),c,:o_custkey,:c_custkey)
    l=hj(rfilter(hrel(s,"lineitem"),r->r.l_returnflag=="R"),o,:l_orderkey,:o_orderkey)
    keys=[:c_custkey,:c_name,:c_acctbal,:c_phone,:n_name,:c_address,:c_comment]
    g=groupby(l,keys,[:revenue=>Sum(rev)])
    a=rmap(g,[:c_custkey,:c_name,:revenue,:c_acctbal,:n_name,:c_address,:c_phone,:c_comment],r->(r.c_custkey,r.c_name,hdiv(r.revenue,10000),hdiv(r.c_acctbal,100),r.n_name,r.c_address,r.c_phone,r.c_comment))
    rlimit(rsort(a,[:revenue=>:desc]),20)
end
function hq11(s;scale=0.001)
    su=hj(hrel(s,"supplier"),rfilter(hrel(s,"nation"),r->r.n_name=="GERMANY"),:s_nationkey,:n_nationkey)
    ps=hj(hrel(s,"partsupp"),su,:ps_suppkey,:s_suppkey)
    total=hsum(ps,r->r.ps_supplycost*r.ps_availqty)
    # Specification fraction is 0.0001/SF, including reduced experimental scales.
    fraction=big(1)//10000 / rationalize(BigInt,scale;tol=eps(scale))
    g=groupby(ps,[:ps_partkey],[:value=>Sum(r->r.ps_supplycost*r.ps_availqty)])
    a=rfilter(g,r->total!==nothing && r.value>total*fraction)
    rsort(rmap(a,a.columns,r->(r.ps_partkey,hdiv(r.value,100))),[:value=>:desc])
end
function hq12(s;scale=0.001)
    l=rfilter(hrel(s,"lineitem"),r->r.l_shipmode in ("MAIL","SHIP")&&r.l_commitdate<r.l_receiptdate&&r.l_shipdate<r.l_commitdate&&"1994-01-01"<=r.l_receiptdate<"1995-01-01")
    x=hj(l,hrel(s,"orders"),:l_orderkey,:o_orderkey)
    g=groupby(x,[:l_shipmode],[:high_line_count=>Sum(r->r.o_orderpriority in ("1-URGENT","2-HIGH") ? 1 : 0),:low_line_count=>Sum(r->r.o_orderpriority in ("1-URGENT","2-HIGH") ? 0 : 1)])
    rsort(g,[:l_shipmode=>:asc])
end
function hq13(s;scale=0.001)
    pattern=SqlLike("%special%requests%")
    o=rfilter(hrel(s,"orders"),r->!pattern(r.o_comment))
    x=hj(hrel(s,"customer"),o,:c_custkey,:o_custkey;kind=:left)
    g=groupby(x,[:c_custkey],[:c_count=>Count(:o_orderkey)])
    rsort(groupby(g,[:c_count],[:custdist=>Count()]),[:custdist=>:desc,:c_count=>:desc])
end
function hq14(s;scale=0.001)
    l=rfilter(hrel(s,"lineitem"),r->"1995-09-01"<=r.l_shipdate<"1995-10-01")
    x=hj(l,hrel(s,"part"),:l_partkey,:p_partkey)
    promo=hsum(x,r->startswith(r.p_type,"PROMO") ? rev(r) : 0)
    hscalar(:promo_revenue,promo===nothing ? nothing : hdiv(100promo,hsum(x,rev)))
end
function hq15(s;scale=0.001)
    l=rfilter(hrel(s,"lineitem"),r->"1996-01-01"<=r.l_shipdate<"1996-04-01")
    g=groupby(l,[:l_suppkey],[:total_revenue=>Sum(rev)])
    maxrev=raggregate(g,Max(:total_revenue))
    x=hj(rfilter(g,r->r.total_revenue==maxrev),hrel(s,"supplier"),:l_suppkey,:s_suppkey)
    a=rmap(x,[:s_suppkey,:s_name,:s_address,:s_phone,:total_revenue],r->(r.s_suppkey,r.s_name,r.s_address,r.s_phone,hdiv(r.total_revenue,10000)))
    rsort(a,[:s_suppkey=>:asc])
end
function hq16(s;scale=0.001)
    p=rfilter(hrel(s,"part"),r->r.p_brand!="Brand#45"&&!startswith(r.p_type,"MEDIUM POLISHED")&&r.p_size in (49,14,23,45,19,3,36,9))
    bad=SqlLike("%Customer%Complaints%")
    ps=hj(hrel(s,"partsupp"),rfilter(hrel(s,"supplier"),r->bad(r.s_comment)),:ps_suppkey,:s_suppkey;kind=:anti)
    x=hj(ps,p,:ps_partkey,:p_partkey)
    g=groupby(x,[:p_brand,:p_type,:p_size],[:supplier_cnt=>CountDistinct(:ps_suppkey)])
    rsort(g,[:supplier_cnt=>:desc,:p_brand=>:asc,:p_type=>:asc,:p_size=>:asc])
end
function hq17(s;scale=0.001)
    l=hrel(s,"lineitem");p=rfilter(hrel(s,"part"),r->r.p_brand=="Brand#23"&&r.p_container=="MED BOX")
    g=groupby(l,[:l_partkey],[:average_quantity=>Avg(:l_quantity)])
    x=hj(hj(l,p,:l_partkey,:p_partkey),g,:l_partkey,:l_partkey)
    a=rfilter(x,r->r.l_quantity*5<r.average_quantity)
    hscalar(:avg_yearly,hdiv(hsum(a,:l_extendedprice),700))
end
function hq18(s;scale=0.001)
    l=hrel(s,"lineitem");large=rfilter(groupby(l,[:l_orderkey],[:sum_quantity=>Sum(:l_quantity)]),r->r.sum_quantity>300)
    o=hj(hj(hrel(s,"orders"),large,:o_orderkey,:l_orderkey),hrel(s,"customer"),:o_custkey,:c_custkey)
    # The subquery sum is also the outer grouped sum because all lines are retained.
    a=rmap(o,[:c_name,:c_custkey,:o_orderkey,:o_orderdate,:o_totalprice,:sum_quantity],r->(r.c_name,r.c_custkey,r.o_orderkey,r.o_orderdate,hdiv(r.o_totalprice,100),r.sum_quantity))
    rlimit(rsort(a,[:o_totalprice=>:desc,:o_orderdate=>:asc]),100)
end
function hq19(s;scale=0.001)
    l=rfilter(hrel(s,"lineitem"),r->r.l_shipmode in ("AIR","AIR REG")&&r.l_shipinstruct=="DELIVER IN PERSON")
    x=hj(l,hrel(s,"part"),:l_partkey,:p_partkey)
    a=rfilter(x) do r
        (r.p_brand=="Brand#12"&&r.p_container in ("SM CASE","SM BOX","SM PACK","SM PKG")&&1<=r.l_quantity<=11&&1<=r.p_size<=5)||
        (r.p_brand=="Brand#23"&&r.p_container in ("MED BAG","MED BOX","MED PKG","MED PACK")&&10<=r.l_quantity<=20&&1<=r.p_size<=10)||
        (r.p_brand=="Brand#34"&&r.p_container in ("LG CASE","LG BOX","LG PACK","LG PKG")&&20<=r.l_quantity<=30&&1<=r.p_size<=15)
    end
    hscalar(:revenue,hdiv(hsum(a,rev),10000))
end
function hq20(s;scale=0.001)
    p=rfilter(hrel(s,"part"),r->startswith(r.p_name,"forest"))
    ps=hj(hrel(s,"partsupp"),p,:ps_partkey,:p_partkey;kind=:semi)
    l=rfilter(hrel(s,"lineitem"),r->"1994-01-01"<=r.l_shipdate<"1995-01-01")
    g=groupby(l,[:l_partkey,:l_suppkey],[:quantity=>Sum(:l_quantity)])
    x=hashjoin(ps,g;on=[:ps_partkey=>:l_partkey,:ps_suppkey=>:l_suppkey])
    eligible=rfilter(x,r->2r.ps_availqty>r.quantity)
    su=hj(hrel(s,"supplier"),rfilter(hrel(s,"nation"),r->r.n_name=="CANADA"),:s_nationkey,:n_nationkey)
    a=hj(su,eligible,:s_suppkey,:ps_suppkey;kind=:semi)
    rsort(rproject(a,[:s_name,:s_address]),[:s_name=>:asc])
end
function hq21(s;scale=0.001)
    l=hrel(s,"lineitem");late=rfilter(l,r->r.l_receiptdate>r.l_commitdate)
    suppliercounts=groupby(l,[:l_orderkey],[:suppliers=>CountDistinct(:l_suppkey)])
    latecounts=groupby(late,[:l_orderkey],[:late_suppliers=>CountDistinct(:l_suppkey)])
    candidates=hj(late,rfilter(suppliercounts,r->r.suppliers>1),:l_orderkey,:l_orderkey)
    candidates=hj(candidates,rfilter(latecounts,r->r.late_suppliers==1),:l_orderkey,:l_orderkey)
    candidates=hj(candidates,rfilter(hrel(s,"orders"),r->r.o_orderstatus=="F"),:l_orderkey,:o_orderkey;kind=:semi)
    su=hj(hrel(s,"supplier"),rfilter(hrel(s,"nation"),r->r.n_name=="SAUDI ARABIA"),:s_nationkey,:n_nationkey)
    x=hj(candidates,su,:l_suppkey,:s_suppkey)
    g=groupby(x,[:s_name],[:numwait=>Count()])
    rlimit(rsort(g,[:numwait=>:desc,:s_name=>:asc]),100)
end
function hq22(s;scale=0.001)
    codes=("13","31","23","29","30","18","17")
    c=rfilter(hrel(s,"customer"),r->r.c_phone[1:2] in codes)
    mean=raggregate(rfilter(c,r->r.c_acctbal>0),Avg(:c_acctbal))
    rich=rfilter(c,r->mean!==nothing&&r.c_acctbal>mean)
    x=hj(rich,hrel(s,"orders"),:c_custkey,:o_custkey;kind=:anti)
    a=rmap(x,[:cntrycode,:balance],r->(r.c_phone[1:2],r.c_acctbal))
    g=groupby(a,[:cntrycode],[:numcust=>Count(),:totacctbal=>Sum(:balance)])
    rsort(rmap(g,g.columns,r->(r.cntrycode,r.numcust,hdiv(r.totacctbal,100))),[:cntrycode=>:asc])
end

const H_QUERIES=[hq1,hq2,hq3,hq4,hq5,hq6,hq7,hq8,hq9,hq10,hq11,hq12,hq13,hq14,hq15,hq16,hq17,hq18,hq19,hq20,hq21,hq22]
function tpch_query(s,id;scale=0.001)
    1<=id<=22 || error("TPC-H query id must be 1..22")
    snapshot(s) do snap
        H_QUERIES[id](snap;scale)
    end
end

function export_answers(s,directory;scale=0.001)
    mkpath(directory)
    for id in 1:22
        answer=tpch_query(s,id;scale)
        open(joinpath(directory,"q$(lpad(id,2,'0')).tsv"),"w") do io
            println(io,join(answer.columns,'\t'))
            for row in answer.rows
                println(io,join([x===nothing ? "\\N" : x isa Rational ? string(numerator(x),"/",denominator(x)) : string(x) for x in row],'\t'))
            end
        end
    end
end

function run_tpch(s;scale=0.001,repetitions=5,warmup=1)
    repetitions>0 || error("repetitions must be positive")
    warmup>=0 || error("warmup must be nonnegative")
    results=Dict{String,Any}();started=time_ns()
    for id in 1:22
        for _ in 1:warmup
            tpch_query(s,id;scale)
        end
        times=Int[];expected=nothing
        for _ in 1:repetitions
            start=time_ns();answer=tpch_query(s,id;scale);push!(times,time_ns()-start)
            if expected===nothing
                expected=answer.rows
            else
                answer.rows==expected || error("Non-deterministic Q$id result")
            end
        end
        results["Q$(lpad(id,2,'0'))"]=merge(latency_summary(times),Dict("result_rows"=>length(expected)))
    end
    Dict("notice"=>BENCHMARK_NOTICE,"scale"=>scale,"generator"=>"deterministic synthetic with disclosed coverage rows; not DBGEN", "repetitions"=>repetitions,"warmup_per_query"=>warmup,"query_ids"=>collect(1:22),"total_wall_seconds_including_warmup"=>(time_ns()-started)/1e9,"queries"=>results)
end
