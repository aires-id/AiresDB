"""Independent SQLite SQL oracle. It is never the measured AiresDB backend.

Inputs: public AiresDB scans exported as TSV, and AiresDB relational results.
Only sqlite3.connect(':memory:') is used. No SQLite database artifact is created.
Prices are cents and discounts percentage integers; SQL converts final results.
This is a correctness oracle for the derived workload, not TPC qualification.
"""
import argparse
import csv
import fractions
import json
import math
import pathlib
import re
import sqlite3
import sys


SQL = {
1: """select l_returnflag,l_linestatus,sum(l_quantity),sum(l_extendedprice)/100.0,
sum(l_extendedprice*(100-l_discount))/10000.0,
sum(l_extendedprice*(100-l_discount)*(100+l_tax))/1000000.0,
avg(l_quantity),avg(l_extendedprice)/100.0,avg(l_discount)/100.0,count(*)
from lineitem where l_shipdate<='1998-09-02' group by l_returnflag,l_linestatus order by l_returnflag,l_linestatus""",
2: """select s_acctbal/100.0,s_name,n_name,p_partkey,p_mfgr,s_address,s_phone,s_comment
from part,supplier,partsupp,nation,region where p_partkey=ps_partkey and s_suppkey=ps_suppkey
and p_size=15 and p_type like '%BRASS' and s_nationkey=n_nationkey and n_regionkey=r_regionkey and r_name='EUROPE'
and ps_supplycost=(select min(ps_supplycost) from partsupp,supplier,nation,region where p_partkey=ps_partkey
and s_suppkey=ps_suppkey and s_nationkey=n_nationkey and n_regionkey=r_regionkey and r_name='EUROPE')
order by s_acctbal desc,n_name,s_name,p_partkey limit 100""",
3: """select l_orderkey,sum(l_extendedprice*(100-l_discount))/10000.0 as revenue,o_orderdate,o_shippriority
from customer,orders,lineitem where c_mktsegment='BUILDING' and c_custkey=o_custkey and l_orderkey=o_orderkey
and o_orderdate<'1995-03-15' and l_shipdate>'1995-03-15' group by l_orderkey,o_orderdate,o_shippriority
order by revenue desc,o_orderdate limit 10""",
4: """select o_orderpriority,count(*) from orders where o_orderdate>='1993-07-01' and o_orderdate<'1993-10-01'
and exists(select * from lineitem where l_orderkey=o_orderkey and l_commitdate<l_receiptdate)
group by o_orderpriority order by o_orderpriority""",
5: """select n_name,sum(l_extendedprice*(100-l_discount))/10000.0 as revenue
from customer,orders,lineitem,supplier,nation,region where c_custkey=o_custkey and l_orderkey=o_orderkey
and l_suppkey=s_suppkey and c_nationkey=s_nationkey and s_nationkey=n_nationkey and n_regionkey=r_regionkey
and r_name='ASIA' and o_orderdate>='1994-01-01' and o_orderdate<'1995-01-01' group by n_name order by revenue desc""",
6: """select sum(l_extendedprice*l_discount)/10000.0 from lineitem where l_shipdate>='1994-01-01'
and l_shipdate<'1995-01-01' and l_discount between 5 and 7 and l_quantity<24""",
7: """select supp_nation,cust_nation,l_year,sum(volume)/10000.0 from
(select n1.n_name as supp_nation,n2.n_name as cust_nation,cast(substr(l_shipdate,1,4) as integer) as l_year,
l_extendedprice*(100-l_discount) as volume from supplier,lineitem,orders,customer,nation n1,nation n2
where s_suppkey=l_suppkey and o_orderkey=l_orderkey and c_custkey=o_custkey and s_nationkey=n1.n_nationkey
and c_nationkey=n2.n_nationkey and ((n1.n_name='FRANCE' and n2.n_name='GERMANY') or (n1.n_name='GERMANY' and n2.n_name='FRANCE'))
and l_shipdate between '1995-01-01' and '1996-12-31') group by supp_nation,cust_nation,l_year order by supp_nation,cust_nation,l_year""",
8: """select o_year,sum(case when nation='BRAZIL' then volume else 0 end)*1.0/sum(volume) from
(select cast(substr(o_orderdate,1,4) as integer) as o_year,l_extendedprice*(100-l_discount) as volume,n2.n_name as nation
from part,supplier,lineitem,orders,customer,nation n1,nation n2,region where p_partkey=l_partkey and s_suppkey=l_suppkey
and l_orderkey=o_orderkey and o_custkey=c_custkey and c_nationkey=n1.n_nationkey and n1.n_regionkey=r_regionkey
and r_name='AMERICA' and s_nationkey=n2.n_nationkey and o_orderdate between '1995-01-01' and '1996-12-31'
and p_type='ECONOMY ANODIZED STEEL') group by o_year order by o_year""",
9: """select nation,o_year,sum(amount)/10000.0 from (select n_name as nation,cast(substr(o_orderdate,1,4) as integer) as o_year,
l_extendedprice*(100-l_discount)-ps_supplycost*l_quantity*100 as amount from part,supplier,lineitem,partsupp,orders,nation
where s_suppkey=l_suppkey and ps_suppkey=l_suppkey and ps_partkey=l_partkey and p_partkey=l_partkey and o_orderkey=l_orderkey
and s_nationkey=n_nationkey and p_name like '%green%') group by nation,o_year order by nation,o_year desc""",
10: """select c_custkey,c_name,sum(l_extendedprice*(100-l_discount))/10000.0 as revenue,c_acctbal/100.0,n_name,c_address,c_phone,c_comment
from customer,orders,lineitem,nation where c_custkey=o_custkey and l_orderkey=o_orderkey and o_orderdate>='1993-10-01'
and o_orderdate<'1994-01-01' and l_returnflag='R' and c_nationkey=n_nationkey
group by c_custkey,c_name,c_acctbal,c_phone,n_name,c_address,c_comment order by revenue desc limit 20""",
11: """select ps_partkey,sum(ps_supplycost*ps_availqty)/100.0 as value from partsupp,supplier,nation
where ps_suppkey=s_suppkey and s_nationkey=n_nationkey and n_name='GERMANY' group by ps_partkey
having sum(ps_supplycost*ps_availqty)>(select sum(ps_supplycost*ps_availqty)*{fraction}
from partsupp,supplier,nation where ps_suppkey=s_suppkey and s_nationkey=n_nationkey and n_name='GERMANY') order by value desc""",
12: """select l_shipmode,sum(case when o_orderpriority in ('1-URGENT','2-HIGH') then 1 else 0 end),
sum(case when o_orderpriority not in ('1-URGENT','2-HIGH') then 1 else 0 end)
from orders,lineitem where o_orderkey=l_orderkey and l_shipmode in ('MAIL','SHIP') and l_commitdate<l_receiptdate
and l_shipdate<l_commitdate and l_receiptdate>='1994-01-01' and l_receiptdate<'1995-01-01' group by l_shipmode order by l_shipmode""",
13: """select c_count,count(*) as custdist from (select c_custkey,count(o_orderkey) as c_count
from customer left outer join orders on c_custkey=o_custkey and o_comment not like '%special%requests%'
group by c_custkey) group by c_count order by custdist desc,c_count desc""",
14: """select 100.0*sum(case when p_type like 'PROMO%' then l_extendedprice*(100-l_discount) else 0 end)
/sum(l_extendedprice*(100-l_discount)) from lineitem,part where l_partkey=p_partkey and l_shipdate>='1995-09-01' and l_shipdate<'1995-10-01'""",
15: """with revenue as (select l_suppkey as supplier_no,sum(l_extendedprice*(100-l_discount)) as total_revenue
from lineitem where l_shipdate>='1996-01-01' and l_shipdate<'1996-04-01' group by l_suppkey)
select s_suppkey,s_name,s_address,s_phone,total_revenue/10000.0 from supplier,revenue where s_suppkey=supplier_no
and total_revenue=(select max(total_revenue) from revenue) order by s_suppkey""",
16: """select p_brand,p_type,p_size,count(distinct ps_suppkey) as supplier_cnt from partsupp,part where p_partkey=ps_partkey
and p_brand<>'Brand#45' and p_type not like 'MEDIUM POLISHED%' and p_size in (49,14,23,45,19,3,36,9)
and ps_suppkey not in (select s_suppkey from supplier where s_comment like '%Customer%Complaints%')
group by p_brand,p_type,p_size order by supplier_cnt desc,p_brand,p_type,p_size""",
17: """select sum(l_extendedprice)/700.0 from lineitem,part where p_partkey=l_partkey and p_brand='Brand#23'
and p_container='MED BOX' and l_quantity<(select 0.2*avg(l_quantity) from lineitem where l_partkey=p_partkey)""",
18: """select c_name,c_custkey,o_orderkey,o_orderdate,o_totalprice/100.0,sum(l_quantity) from customer,orders,lineitem
where o_orderkey in (select l_orderkey from lineitem group by l_orderkey having sum(l_quantity)>300)
and c_custkey=o_custkey and o_orderkey=l_orderkey group by c_name,c_custkey,o_orderkey,o_orderdate,o_totalprice
order by o_totalprice desc,o_orderdate limit 100""",
19: """select sum(l_extendedprice*(100-l_discount))/10000.0 from lineitem,part where p_partkey=l_partkey
and l_shipmode in ('AIR','AIR REG') and l_shipinstruct='DELIVER IN PERSON' and
((p_brand='Brand#12' and p_container in ('SM CASE','SM BOX','SM PACK','SM PKG') and l_quantity between 1 and 11 and p_size between 1 and 5)
or (p_brand='Brand#23' and p_container in ('MED BAG','MED BOX','MED PKG','MED PACK') and l_quantity between 10 and 20 and p_size between 1 and 10)
or (p_brand='Brand#34' and p_container in ('LG CASE','LG BOX','LG PACK','LG PKG') and l_quantity between 20 and 30 and p_size between 1 and 15))""",
20: """select s_name,s_address from supplier,nation where s_suppkey in
(select ps_suppkey from partsupp where ps_partkey in (select p_partkey from part where p_name like 'forest%')
and ps_availqty>(select 0.5*sum(l_quantity) from lineitem where l_partkey=ps_partkey and l_suppkey=ps_suppkey
and l_shipdate>='1994-01-01' and l_shipdate<'1995-01-01')) and s_nationkey=n_nationkey and n_name='CANADA' order by s_name""",
21: """select s_name,count(*) as numwait from supplier,lineitem l1,orders,nation where s_suppkey=l1.l_suppkey
and o_orderkey=l1.l_orderkey and o_orderstatus='F' and l1.l_receiptdate>l1.l_commitdate
and exists(select * from lineitem l2 where l2.l_orderkey=l1.l_orderkey and l2.l_suppkey<>l1.l_suppkey)
and not exists(select * from lineitem l3 where l3.l_orderkey=l1.l_orderkey and l3.l_suppkey<>l1.l_suppkey and l3.l_receiptdate>l3.l_commitdate)
and s_nationkey=n_nationkey and n_name='SAUDI ARABIA' group by s_name order by numwait desc,s_name limit 100""",
22: """select cntrycode,count(*),sum(c_acctbal)/100.0 from
(select substr(c_phone,1,2) as cntrycode,c_acctbal from customer where substr(c_phone,1,2) in ('13','31','23','29','30','18','17')
and c_acctbal>(select avg(c_acctbal) from customer where c_acctbal>0 and substr(c_phone,1,2) in ('13','31','23','29','30','18','17'))
and not exists(select * from orders where o_custkey=c_custkey)) group by cntrycode order by cntrycode""",
}

# Result column types are independent of the input importer; country code in Q22
# must stay text although it happens to consist of digits.
TEXT_COLUMNS = {1:{0,1},2:{1,2,4,5,6,7},3:{2},4:{0},5:{0},7:{0,1},9:{0},
10:{1,4,5,6,7},12:{0},15:{1,2,3},16:{0,1},18:{0,3},20:{0,1},21:{0},22:{0}}
ORDER_KEYS = {1:[(0,1),(1,1)],2:[(0,-1),(2,1),(1,1),(3,1)],3:[(1,-1),(2,1)],
4:[(0,1)],5:[(1,-1)],7:[(0,1),(1,1),(2,1)],8:[(0,1)],9:[(0,1),(1,-1)],10:[(2,-1)],
11:[(1,-1)],12:[(0,1)],13:[(1,-1),(0,-1)],15:[(0,1)],16:[(3,-1),(0,1),(1,1),(2,1)],
18:[(4,-1),(3,1)],20:[(0,1)],21:[(1,-1),(0,1)],22:[(0,1)]}

def is_ordered(rows,id):
    for left,right in zip(rows,rows[1:]):
        for index,direction in ORDER_KEYS.get(id,[]):
            a,b=left[index],right[index]
            if a==b: continue
            if a is None: return False
            if b is None: break
            if (a>b if direction==1 else a<b): return False
            break
    return True

def import_data(conn, directory):
    counts = {}
    for file in sorted(directory.glob('*.tsv')):
        with file.open(encoding='utf-8', newline='') as stream:
            rows=list(csv.reader(stream,delimiter='\t'))
        header, rows=rows[0],rows[1:]
        numeric=[all(r[i]=='\\N' or re.fullmatch(r'-?\d+',r[i]) for r in rows) for i in range(len(header))]
        # Every official name/address/comment/phone/date is explicitly textual.
        textual=('name','address','phone','comment','type','brand','mfgr','container','date','priority','clerk','status','flag','instruct','mode','segment')
        numeric=[x and (header[i]=='o_shippriority' or not any(part in header[i] for part in textual)) for i,x in enumerate(numeric)]
        columns=','.join('"'+name+'" '+('INTEGER' if numeric[i] else 'TEXT') for i,name in enumerate(header))
        conn.execute(f'CREATE TABLE "{file.stem}" ({columns})')
        values=[[None if x=='\\N' else int(x) if numeric[i] else x for i,x in enumerate(r)] for r in rows]
        conn.executemany(f'INSERT INTO "{file.stem}" VALUES ({",".join("?" for _ in header)})', values)
        counts[file.stem]=len(values)
    # Oracle indexes affect only validation latency, never measured AiresDB plans.
    for table,cols in [('lineitem','l_orderkey'),('lineitem','l_partkey,l_suppkey'),('partsupp','ps_partkey,ps_suppkey'),('orders','o_orderkey'),('orders','o_custkey')]:
        conn.execute(f'CREATE INDEX "idx_{table}_{cols.replace(",","_")}" ON {table} ({cols})')
    return counts

def parse_answer(value,id,index):
    if value=='\\N': return None
    if index in TEXT_COLUMNS.get(id,set()): return value
    return fractions.Fraction(value)

def equal(left,right):
    if left is None or right is None: return left is None and right is None
    if isinstance(left,str) or isinstance(right,str): return left==right
    return math.isclose(float(left),float(right),rel_tol=1e-11,abs_tol=1e-7)

def sortkey(row):
    return tuple((0,'') if x is None else (1,float(x)) if isinstance(x,(int,float,fractions.Fraction)) else (2,x) for x in row)

def verify(data,answers,scale):
    conn=sqlite3.connect(':memory:')
    conn.execute('PRAGMA case_sensitive_like=ON')
    counts=import_data(conn,data)
    results=[]
    for id in range(1,23):
        sql=SQL[id].format(fraction=repr(0.0001/scale))
        expected=conn.execute(sql).fetchall()
        file=answers/f'q{id:02d}.tsv'
        with file.open(encoding='utf-8',newline='') as stream:
            entries=list(csv.reader(stream,delimiter='\t'))
        actual=[tuple(parse_answer(x,id,i) for i,x in enumerate(row)) for row in entries[1:]]
        ordered=is_ordered(actual,id)
        # SQL ordering ties can be permuted; compare the full output multiset.
        actual=sorted(actual,key=sortkey);expected=sorted(expected,key=sortkey)
        ok=ordered and len(actual)==len(expected) and all(len(a)==len(b) and all(equal(x,y) for x,y in zip(a,b)) for a,b in zip(actual,expected))
        results.append({'query':f'Q{id:02d}','passed':ok,'order_by_passed':ordered,'rows':len(actual),'oracle_rows':len(expected)})
        print(f'Q{id:02d}: {"PASS" if ok else "FAIL"} AiresDB={len(actual)} SQLite={len(expected)}')
        if not ok:
            for index,(a,b) in enumerate(zip(actual,expected)):
                if not all(equal(x,y) for x,y in zip(a,b)):
                    print(' first mismatch',index,'AiresDB',a,'oracle',b);break
    conn.close()
    return {'passed':all(r['passed'] for r in results),'oracle':'Python sqlite3 in-memory independent SQL','scale':scale,'cardinalities':counts,'queries':results}

def main():
    parser=argparse.ArgumentParser();parser.add_argument('data',type=pathlib.Path);parser.add_argument('answers',type=pathlib.Path)
    parser.add_argument('--scale',type=float,default=0.001);parser.add_argument('--report',type=pathlib.Path)
    args=parser.parse_args();report=verify(args.data,args.answers,args.scale)
    if args.report:
        args.report.parent.mkdir(parents=True,exist_ok=True);args.report.write_text(json.dumps(report,indent=2),encoding='utf-8')
    return 0 if report['passed'] else 1

if __name__=='__main__':sys.exit(main())
