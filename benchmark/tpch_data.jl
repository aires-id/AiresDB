# Deterministic synthetic, reduced-size TPC-H-shaped data. This is not DBGEN.
# Monetary values are exact integer cents; discount/tax values integer percent.
# Dates use sortable ISO text, preserving the date comparisons used below.
const H_SCHEMA = Dict(
"region"=>[("r_regionkey","I"),("r_name","C(25)"),("r_comment","C(152)")],
"nation"=>[("n_nationkey","I"),("n_name","C(25)"),("n_regionkey","I"),("n_comment","C(152)")],
"supplier"=>[("s_suppkey","I"),("s_name","C(25)"),("s_address","C(40)"),("s_nationkey","I"),("s_phone","C(15)"),("s_acctbal","I"),("s_comment","C(101)")],
"customer"=>[("c_custkey","I"),("c_name","C(25)"),("c_address","C(40)"),("c_nationkey","I"),("c_phone","C(15)"),("c_acctbal","I"),("c_mktsegment","C(10)"),("c_comment","C(117)")],
"part"=>[("p_partkey","I"),("p_name","C(55)"),("p_mfgr","C(25)"),("p_brand","C(10)"),("p_type","C(25)"),("p_size","I"),("p_container","C(10)"),("p_retailprice","I"),("p_comment","C(23)")],
"partsupp"=>[("ps_partkey","I"),("ps_suppkey","I"),("ps_availqty","I"),("ps_supplycost","I"),("ps_comment","C(199)")],
"orders"=>[("o_orderkey","I"),("o_custkey","I"),("o_orderstatus","C(1)"),("o_totalprice","I"),("o_orderdate","C(10)"),("o_orderpriority","C(15)"),("o_clerk","C(15)"),("o_shippriority","I"),("o_comment","C(79)")],
"lineitem"=>[("l_orderkey","I"),("l_partkey","I"),("l_suppkey","I"),("l_linenumber","I"),("l_quantity","I"),("l_extendedprice","I"),("l_discount","I"),("l_tax","I"),("l_returnflag","C(1)"),("l_linestatus","C(1)"),("l_shipdate","C(10)"),("l_commitdate","C(10)"),("l_receiptdate","C(10)"),("l_shipinstruct","C(25)"),("l_shipmode","C(10)"),("l_comment","C(44)")])
const H_KEYS=Dict("region"=>["r_regionkey"],"nation"=>["n_nationkey"],"supplier"=>["s_suppkey"],"customer"=>["c_custkey"],"part"=>["p_partkey"],"partsupp"=>["ps_partkey","ps_suppkey"],"orders"=>["o_orderkey"],"lineitem"=>["l_orderkey","l_linenumber"])
const H_NATIONS=[("ALGERIA",0),("ARGENTINA",1),("BRAZIL",1),("CANADA",1),("EGYPT",4),("ETHIOPIA",0),("FRANCE",3),("GERMANY",3),("INDIA",2),("INDONESIA",2),("IRAN",4),("IRAQ",4),("JAPAN",2),("JORDAN",4),("KENYA",0),("MOROCCO",0),("MOZAMBIQUE",0),("PERU",1),("CHINA",2),("ROMANIA",3),("SAUDI ARABIA",4),("VIETNAM",2),("RUSSIA",3),("UNITED KINGDOM",3),("UNITED STATES",1)]

function tpch_data(; scale=0.001,seed=20260903,coverage=true)
    0<scale<=10 || error("scale must be in (0,10]")
    rng=MersenneTwister(seed);np=max(20,round(Int,200000scale));ns=max(25,round(Int,10000scale));nc=max(25,round(Int,150000scale));no=max(100,round(Int,1500000scale))
    data=Dict(t=>Vector{Any}[] for t in keys(H_SCHEMA))
    for (k,name) in enumerate(["AFRICA","AMERICA","ASIA","EUROPE","MIDDLE EAST"])
        push!(data["region"],Any[k-1,name,"region comment"])
    end
    for (k,(name,r)) in enumerate(H_NATIONS)
        push!(data["nation"],Any[k-1,name,r,"nation comment"])
    end
    for s in 1:ns
        n=(s-1)%25
        push!(data["supplier"],Any[s,"Supplier$(lpad(s,9,'0'))","Supplier address $s",n,"$(lpad(n+10,2,'0'))-123-456-7890",rand(rng,-99999:999999),s%17==0 ? "Customer serious Complaints" : "supplier comment"])
    end
    for c in 1:nc
        n=(c-1)%25
        push!(data["customer"],Any[c,"Customer$(lpad(c,9,'0'))","Customer address $c",n,"$(lpad(n+10,2,'0'))-123-456-7890",rand(rng,-99999:999999),["BUILDING","AUTOMOBILE","MACHINERY","HOUSEHOLD","FURNITURE"][mod1(c,5)],"customer comment"])
    end
    suppliers=Dict{Int,Vector{Int}}()
    types=["ECONOMY ANODIZED STEEL","STANDARD BRASS","PROMO BURNISHED COPPER","MEDIUM POLISHED TIN","LARGE BRUSHED NICKEL"]
    containers=["SM CASE","SM BOX","SM PACK","SM PKG","MED BAG","MED BOX","MED PKG","MED PACK","LG CASE","LG BOX","LG PACK","LG PKG","WRAP PKG"]
    for p in 1:np
        push!(data["part"],Any[p,"$(["green","forest","blue","red"][mod1(p,4)]) part $p","Manufacturer#$(mod1(p,5))","Brand#$([12,23,34,45][mod1(p,4)])",types[mod1(p,5)],rand(rng,1:50),containers[mod1(p,13)],rand(rng,90000:200000),"part comment"])
        supps=unique([mod1(p+j*max(1,div(ns,4)),ns) for j in 0:3]);suppliers[p]=supps
        for s in supps
            push!(data["partsupp"],Any[p,s,rand(rng,1:9999),rand(rng,100:100000),"partsupp comment"])
        end
    end
    for o in 1:no
        date=Date(1992,1,1)+Day(rand(rng,0:2405));cid=rand(rng,1:max(1,floor(Int,0.8nc)))
        push!(data["orders"],Any[o,cid,date<Date(1995,6,17) ? "F" : "O",0,string(date),["1-URGENT","2-HIGH","3-MEDIUM","4-NOT SPECIFIED","5-LOW"][mod1(o,5)],"Clerk$(lpad(mod1(o,100),9,'0'))",0,o%13==0 ? "some special pending requests" : "regular order"])
        total=0
        for n in 1:rand(rng,1:7)
            p=rand(rng,1:np);s=rand(rng,suppliers[p]);quantity=rand(rng,1:50);price=quantity*data["part"][p][8]
            discount=rand(rng,0:10);tax=rand(rng,0:8);ship=date+Day(rand(rng,1:121));commit=date+Day(rand(rng,30:90));receipt=ship+Day(rand(rng,1:30))
            push!(data["lineitem"],Any[o,p,s,n,quantity,price,discount,tax,receipt<Date(1995,6,17) ? (isodd(n) ? "R" : "A") : "N",ship<Date(1995,6,17) ? "F" : "O",string(ship),string(commit),string(receipt),isodd(n) ? "DELIVER IN PERSON" : "TAKE BACK RETURN",["AIR","AIR REG","MAIL","SHIP","RAIL","TRUCK","FOB"][mod1(o+n,7)],"line comment"])
            total+=div(price*(100-discount)*(100+tax),10000)
        end
        data["orders"][end][4]=total
    end
    # Hand-designed corner cases supplement generated data, so all22 query families
    # can be tested even at tiny scales. They are disclosed in result metadata.
    if coverage
        add_tpch_coverage!(data,np,ns,nc,no)
    end
    data
end

function add_tpch_coverage!(data,np,ns,nc,no)
    # Suppliers 3/4/7/8/9/21 represent Brazil/Canada/France/Germany/India/Saudi.
    parts=[("forest green brass","Brand#12","STANDARD BRASS",15,"SM BOX"),
           ("green steel","Brand#23","ECONOMY ANODIZED STEEL",3,"MED BOX"),
           ("green promo","Brand#34","PROMO COPPER",9,"LG BOX"),
           ("forest green lowcost","Brand#23","STANDARD TIN",14,"MED BOX"),
           ("forest green small","Brand#12","STANDARD TIN",3,"SM BOX")]
    for (i,(name,brand,type,size,container)) in enumerate(parts)
        p=np+i
        push!(data["part"],Any[p,name,"Manufacturer#1",brand,type,size,container,10000,"coverage"])
        for s in (3,4,7,8,9,21)
            push!(data["partsupp"],Any[p,s,9999,(s==8 && i==1) ? 100000 : 100+s,"coverage"])
        end
    end
    # Customers have explicit geography and one intentionally has no orders.
    for (i,nation) in enumerate((6,7,2,8,3,20))
        push!(data["customer"],Any[nc+i,"Coverage$i","Coverage address",nation,"$(lpad(nation+10,2,'0'))-000-000-0000",900000+i,"BUILDING","coverage"])
    end
    oid=no
    function add_order(cid,date,lines; status="F",priority="1-URGENT",comment="coverage")
        oid+=1;total=0
        for (n,line) in enumerate(lines)
            p,s,q,ship,commit,receipt,disc,mode,flag=line
            price=q*10000;total+=div(price*(100-disc),100)
            push!(data["lineitem"],Any[oid,np+p,s,n,q,price,disc,2,flag,"F",ship,commit,receipt,"DELIVER IN PERSON",mode,"coverage"])
        end
        push!(data["orders"],Any[oid,nc+cid,status,total,date,priority,"Clerk000000001",0,comment])
    end
    add_order(1,"1995-03-01",[(1,8,5,"1995-03-20","1995-03-21","1995-03-22",6,"AIR","R"),(2,7,12,"1995-03-21","1995-03-22","1995-03-23",6,"AIR","R")])
    add_order(2,"1996-01-01",[(1,7,8,"1996-01-10","1996-01-11","1996-01-12",6,"AIR","R")])
    add_order(3,"1995-07-01",[(2,3,20,"1995-07-10","1995-07-11","1995-07-12",6,"AIR","R")])
    add_order(3,"1996-07-01",[(2,8,20,"1996-07-10","1996-07-11","1996-07-12",6,"AIR","R")])
    add_order(4,"1994-05-01",[(1,9,20,"1994-05-10","1994-05-11","1994-05-12",6,"MAIL","R")])
    add_order(1,"1993-07-15",[(1,7,10,"1993-07-20","1993-07-21","1993-07-22",6,"SHIP","R")])
    add_order(1,"1993-10-15",[(1,7,10,"1993-10-20","1993-10-21","1993-10-22",6,"SHIP","R")])
    add_order(5,"1994-06-01",[(1,4,10,"1994-06-10","1994-06-11","1994-06-12",6,"SHIP","R")])
    add_order(1,"1995-08-31",[(3,7,25,"1995-09-01","1995-09-02","1995-09-03",6,"AIR","R")])
    add_order(1,"1994-01-01",[(4,4,1,"1994-01-10","1994-01-11","1994-01-12",6,"AIR","R"),(4,4,40,"1994-01-10","1994-01-11","1994-01-12",6,"AIR","R"),(4,4,40,"1994-01-10","1994-01-11","1994-01-12",6,"AIR","R")])
    add_order(1,"1994-07-01",[(5,4,50,"1994-07-10","1994-07-11","1994-07-12",6,"AIR","R") for _ in 1:7])
    add_order(6,"1994-02-01",[(5,21,2,"1994-02-10","1994-02-11","1994-02-12",6,"AIR","R"),(5,4,2,"1994-02-10","1994-02-12","1994-02-11",6,"AIR","R")])
    # High-balance customer without orders, selected by Q22 country code 13.
    push!(data["customer"],Any[nc+7,"NoOrders","Coverage address",3,"13-000-000-0000",999999,"BUILDING","coverage"])
end

function load_tpch!(s; scale=0.001,seed=20260903)
    data=tpch_data(;scale,seed)
    counts=Dict(k=>length(v) for (k,v) in data)
    for table in sort(collect(keys(data)))
        create_schema!(s,table,H_SCHEMA[table],H_KEYS[table]);load_rows!(s,table,data[table]);empty!(data[table])
    end
    counts
end

"Parse a DBGEN decimal into exact scaled Int64; reject fractional loss/overflow."
function parse_scaled_integer(text,digits)
    match(r"^[+-]?\d+(\.\d+)?$",text)===nothing && throw(ArgumentError("invalid DBGEN numeric '$text'"))
    negative=startswith(text,"-");unsigned=lstrip(text,['+','-']);parts=split(unsigned,'.')
    whole=parse(BigInt,parts[1]);fraction=length(parts)==2 ? parts[2] : ""
    if length(fraction)>digits
        all(==('0'),fraction[digits+1:end]) || throw(ArgumentError("fractional loss in '$text'"))
        fraction=first(fraction,digits)
    end
    units=whole*big(10)^digits+(isempty(fraction) ? 0 : parse(BigInt,rpad(fraction,digits,'0')))
    Int64(negative ? -units : units)
end

const H_SCALED_FIELDS=Set(["s_acctbal","c_acctbal","p_retailprice","ps_supplycost","o_totalprice","l_extendedprice","l_discount","l_tax"])
"Load the eight unmodified DBGEN .tbl files through public AiresDB batch inserts."
function load_tpch_dbgen!(s,directory;batch=5000)
    all(isfile(joinpath(directory,t*".tbl")) for t in keys(H_SCHEMA)) || error("DBGEN import requires all eight table.tbl files")
    counts=Dict{String,Int}()
    for table in sort(collect(keys(H_SCHEMA)))
        columns=H_SCHEMA[table];create_schema!(s,table,columns,H_KEYS[table]);rows=Vector{Any}[];count=0
        open(joinpath(directory,table*".tbl")) do io
            for line in eachline(io)
                fields=split(line,'|';keepempty=true)
                !isempty(fields) && isempty(last(fields)) && pop!(fields)
                length(fields)==length(columns) || error("DBGEN $table row $(count+1) has wrong field count")
                values=Any[(kind=="I" ? parse_scaled_integer(String(value),name in H_SCALED_FIELDS ? 2 : 0) : String(value)) for ((name,kind),value) in zip(columns,fields)]
                push!(rows,values);count+=1
                if length(rows)>=batch
                    load_rows!(s,table,rows;batch);empty!(rows)
                end
            end
        end
        isempty(rows) || load_rows!(s,table,rows;batch)
        counts[table]=count
    end
    counts
end

function export_tpch(s,directory)
    mkpath(directory)
    snapshot(s) do snap
        for table in sort(collect(keys(H_SCHEMA)))
            open(joinpath(directory,table*".tsv"),"w") do io
                println(io,join(first.(H_SCHEMA[table]),'\t'))
                for row in scan_rows(snap,table)
                    println(io,join([x===nothing ? "\\N" : replace(string(x),'\t'=>' ','\n'=>' ') for x in row],'\t'))
                end
            end
        end
    end
end
