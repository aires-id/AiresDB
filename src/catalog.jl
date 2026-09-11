# SPDX-FileCopyrightText: 2026 Aires Zam Wibisono
# SPDX-License-Identifier: NCSA

mutable struct Table
    name::String
    columns::Vector{ColumnDef}
    rows::Vector{Row}
    next_ids::Dict{String,Int128}
    row_ids::Vector{UInt128}
    row_stamps::Vector{UInt64}
    positions::Dict{UInt128,Int}
    indexes::Dict{Tuple,Dict{Tuple,UInt128}}
    changes::Dict{UInt128,Union{Nothing,Row}}
    # A statement visits a physical row at most once through the public
    # executor/API paths.  A compact vector avoids a second hash table holding
    # every row ID during large bulk inserts.
    statement_changes::Vector{UInt128}
    # Staging tables may share immutable catalog storage with their snapshot.
    # Each bit is cleared when the corresponding field is first mutated.
    shared_fields::UInt8
    # Replacements can remain sparse while the table shell is staged. Keys are
    # stable logical positions, so a one-row UPDATE need not copy `rows`.
    row_overrides::Dict{Int,Row}
    # Commit CSNs follow the same sparse path; the base stamp vector stays
    # shared until a structural operation needs a dense representation.
    row_stamp_overrides::Dict{Int,UInt64}
    # Sparse changes layered over immutable logical indexes. Zero is a
    # tombstone. Small transactions therefore copy only keys they modify.
    index_overrides::Dict{Tuple,Dict{Tuple,UInt128}}
    # Derived, non-durable optimizer statistics. They are invalidated on every
    # logical row/schema mutation and rebuilt lazily for the current snapshot.
    statistics::Any
end
const LOGICAL_INDEX_ROW_LIMIT = 100_000
const TABLE_SHARED_ROWS = UInt8(0x01)
const TABLE_SHARED_COLUMNS = UInt8(0x02)
const TABLE_SHARED_NEXT_IDS = UInt8(0x04)
const TABLE_SHARED_ROW_IDS = UInt8(0x08)
const TABLE_SHARED_ROW_STAMPS = UInt8(0x10)
const TABLE_SHARED_POSITIONS = UInt8(0x20)
const TABLE_SHARED_INDEXES = UInt8(0x40)
const TABLE_SHARED_ALL = TABLE_SHARED_ROWS | TABLE_SHARED_COLUMNS | TABLE_SHARED_NEXT_IDS |
    TABLE_SHARED_ROW_IDS | TABLE_SHARED_ROW_STAMPS | TABLE_SHARED_POSITIONS | TABLE_SHARED_INDEXES

# Compatibility constructor for the stable internal 10-field Table shape.
Table(name::String,columns::Vector{ColumnDef},rows::Vector{Row},next_ids::Dict{String,Int128},
      row_ids::Vector{UInt128},row_stamps::Vector{UInt64},positions::Dict{UInt128,Int},
      indexes::Dict{Tuple,Dict{Tuple,UInt128}},changes::Dict{UInt128,Union{Nothing,Row}},
      statement_changes::Vector{UInt128}) =
    Table(name,columns,rows,next_ids,row_ids,row_stamps,positions,indexes,changes,statement_changes,UInt8(0),
        Dict{Int,Row}(),Dict{Int,UInt64}(),Dict{Tuple,Dict{Tuple,UInt128}}(),nothing)

# Compatibility constructor for callers that already provide the COW flags.
Table(name::String,columns::Vector{ColumnDef},rows::Vector{Row},next_ids::Dict{String,Int128},
      row_ids::Vector{UInt128},row_stamps::Vector{UInt64},positions::Dict{UInt128,Int},
      indexes::Dict{Tuple,Dict{Tuple,UInt128}},changes::Dict{UInt128,Union{Nothing,Row}},
      statement_changes::Vector{UInt128},shared_fields::UInt8) =
    Table(name,columns,rows,next_ids,row_ids,row_stamps,positions,indexes,changes,statement_changes,
        shared_fields,Dict{Int,Row}(),Dict{Int,UInt64}(),Dict{Tuple,Dict{Tuple,UInt128}}(),nothing)

function Table(name::String,columns::Vector{ColumnDef},rows::Vector{Row},next_ids::Dict{String,Int128})
    ids = UInt128[uuid4().value for _ in rows]
    Table(name,columns,rows,next_ids,ids,zeros(UInt64,length(rows)),
          Dict(id=>i for (i,id) in enumerate(ids)),Dict{Tuple,Dict{Tuple,UInt128}}(),
          Dict{UInt128,Union{Nothing,Row}}(),UInt128[])
end

function unique_specs(table::Table)
    specs = Tuple[]
    pk = Tuple(findall(c->c.primary,table.columns))
    isempty(pk) || push!(specs,pk)
    for (i,c) in enumerate(table.columns)
        c.unique && !((i,) in specs) && push!(specs,(i,))
    end
    specs
end
primary_spec(table::Table) = Tuple(findall(c->c.primary,table.columns))
row_key(row::Row,spec::Tuple) = Tuple(value_key(row[i]) for i in spec)

@inline function logical_index_get(table::Table,spec::Tuple,key::Tuple)::UInt128
    overlay = get(table.index_overrides,spec,nothing)
    if overlay !== nothing && haskey(overlay,key)
        return overlay[key]
    end
    base = get(table.indexes,spec,nothing)
    base === nothing ? UInt128(0) : get(base,key,UInt128(0))
end

"""Occasionally fold a large sparse index delta into one copied base index."""
function compact_index_overrides!(table::Table)
    for (spec,overlay) in collect(table.index_overrides)
        base = get(table.indexes,spec,nothing)
        base === nothing && continue
        length(overlay) <= max(4096,length(base) ÷ 4) && continue
        if table.shared_fields & TABLE_SHARED_INDEXES != 0
            table.indexes = copy(table.indexes) # nested maps remain shared
            table.shared_fields = table.shared_fields & (UInt8(0xff) ⊻ TABLE_SHARED_INDEXES)
        end
        merged = copy(base)
        for (key,id) in overlay
            iszero(id) ? delete!(merged,key) : (merged[key] = id)
        end
        table.indexes[spec] = merged
        delete!(table.index_overrides,spec)
    end
    table
end

function build_indexes!(table::Table)
    if length(table.rows) > LOGICAL_INDEX_ROW_LIMIT
        _validate_unique_specs_without_indexes!(table)
        table.indexes = Dict{Tuple,Dict{Tuple,UInt128}}()
        table.index_overrides = Dict{Tuple,Dict{Tuple,UInt128}}()
        table.positions = Dict(id=>i for (i,id) in enumerate(table.row_ids))
        table.shared_fields = table.shared_fields & (UInt8(0xff) ⊻ TABLE_SHARED_INDEXES) &
            (UInt8(0xff) ⊻ TABLE_SHARED_POSITIONS)
        return table
    end
    indexes = Dict{Tuple,Dict{Tuple,UInt128}}()
    for spec in unique_specs(table)
        index = Dict{Tuple,UInt128}()
        for (i,row) in enumerate(table_rows(table))
            key = row_key(row,spec)
            any(isnothing,key) && continue
            haskey(index,key) && constraint("Nilai $key pada kolom $(join([table.columns[j].name for j in spec], " + ")) harus unik.")
            index[key] = table.row_ids[i]
        end
        indexes[spec] = index
    end
    table.indexes = indexes
    table.index_overrides = Dict{Tuple,Dict{Tuple,UInt128}}()
    table.positions = Dict(id=>i for (i,id) in enumerate(table.row_ids))
    table.shared_fields = table.shared_fields & (UInt8(0xff) ⊻ TABLE_SHARED_INDEXES) &
        (UInt8(0xff) ⊻ TABLE_SHARED_POSITIONS)
    table
end

"""Validate a large table one unique specification at a time.

Single integer indexes use an isbits vector and no boxed Tuple dictionary.
Other schemas retain the generic Set validation, but release each set before
the next index. Persistent B+Trees remain the retained index for large tables.
"""
function _validate_unique_specs_without_indexes!(table::Table)
    rows = table_rows(table)
    for spec in unique_specs(table)
        label = spec == primary_spec(table) ? "Primary Key" : "kolom"
        if length(spec) == 1 && table.columns[spec[1]].kind == :I
            values = Int64[]
            sizehint!(values,length(table.rows))
            for row in rows
                value = row[spec[1]]
                value === nothing || push!(values,value::Int64)
            end
            sort!(values)
            for index in 2:length(values)
                values[index-1] == values[index] &&
                    constraint("Nilai $(values[index]) pada $label $(table.columns[spec[1]].name) harus unik.")
            end
        else
            seen = Set{Tuple}()
            for row in rows
                key = row_key(row,spec)
                any(isnothing,key) && continue
                key in seen && constraint("Nilai $key pada $label harus unik.")
                push!(seen,key)
            end
        end
        GC.gc(false)
    end
    nothing
end

function copy_table(table::Table)
    rows = isempty(table.row_overrides) ? copy(table.rows) : table_rows(table)
    stamps = isempty(table.row_stamp_overrides) ? copy(table.row_stamps) : table_stamps(table)
    Table(table.name,copy(table.columns),rows,copy(table.next_ids),copy(table.row_ids),
          stamps,copy(table.positions),Dict(k=>copy(v) for (k,v) in table.indexes),
          copy(table.changes),UInt128[],UInt8(0),Dict{Int,Row}(),Dict{Int,UInt64}(),
          Dict(k=>copy(v) for (k,v) in table.index_overrides),table.statistics)
end

"""Create an isolated table shell without copying its large immutable fields."""
function copy_table_for_mutation(table::Table)
    Table(table.name,table.columns,table.rows,table.next_ids,table.row_ids,table.row_stamps,
          table.positions,table.indexes,copy(table.changes),copy(table.statement_changes),TABLE_SHARED_ALL,
          copy(table.row_overrides),copy(table.row_stamp_overrides),
          Dict(k=>copy(v) for (k,v) in table.index_overrides),nothing)
end

"""Return a row as seen by a logical snapshot, including sparse replacements."""
@inline table_row(table::Table,index::Int) = get(table.row_overrides,index,table.rows[index])

function table_rows(table::Table)::Vector{Row}
    isempty(table.row_overrides) && return table.rows
    rows = copy(table.rows)
    for (index,row) in table.row_overrides
        1 <= index <= length(rows) || constraint("Overlay row berada di luar tabel.")
        rows[index] = row
    end
    rows
end

@inline table_stamp(table::Table,index::Int) = get(table.row_stamp_overrides,index,table.row_stamps[index])

function table_stamps(table::Table)::Vector{UInt64}
    isempty(table.row_stamp_overrides) && return table.row_stamps
    stamps = copy(table.row_stamps)
    for (index,stamp) in table.row_stamp_overrides
        1 <= index <= length(stamps) || constraint("Overlay stamp berada di luar tabel.")
        stamps[index] = stamp
    end
    stamps
end

function materialize_table_stamps!(table::Table)
    isempty(table.row_stamp_overrides) || begin
        if table.shared_fields & TABLE_SHARED_ROW_STAMPS != 0
            table.row_stamps = copy(table.row_stamps)
            table.shared_fields = table.shared_fields & (UInt8(0xff) ⊻ TABLE_SHARED_ROW_STAMPS)
        end
        for (index,stamp) in table.row_stamp_overrides
            1 <= index <= length(table.row_stamps) || constraint("Overlay stamp berada di luar tabel.")
            table.row_stamps[index] = stamp
        end
        empty!(table.row_stamp_overrides)
    end
    if table.shared_fields & TABLE_SHARED_ROW_STAMPS != 0
        table.row_stamps = copy(table.row_stamps)
        table.shared_fields = table.shared_fields & (UInt8(0xff) ⊻ TABLE_SHARED_ROW_STAMPS)
    end
    table
end

function materialize_table_rows!(table::Table)
    isempty(table.row_overrides) || begin
        if table.shared_fields & TABLE_SHARED_ROWS != 0
            table.rows = copy(table.rows)
            table.shared_fields = table.shared_fields & (UInt8(0xff) ⊻ TABLE_SHARED_ROWS)
        end
        for (index,row) in table.row_overrides
            1 <= index <= length(table.rows) || constraint("Overlay row berada di luar tabel.")
            table.rows[index] = row
        end
        empty!(table.row_overrides)
    end
    if table.shared_fields & TABLE_SHARED_ROWS != 0
        table.rows = copy(table.rows)
        table.shared_fields = table.shared_fields & (UInt8(0xff) ⊻ TABLE_SHARED_ROWS)
    end
    table
end
struct ViewDefinition
    name::String
    query::SelectQuery
end
mutable struct Database
    name::String
    created::DateTime
    tables::Dict{String,Table}
    views::Dict{String,ViewDefinition}
end
Database(name::String) = Database(name, now(UTC), Dict{String,Table}(), Dict{String,ViewDefinition}())
copy_database(db::Database) = Database(db.name,db.created,copy(db.tables),copy(db.views))

function validate_identifier(name::AbstractString)
    occursin(r"^[\p{L}_][\p{L}\p{N}_]*$", name) || fail("Nama '$name' harus diawali huruf/underscore dan hanya memuat huruf, angka, atau underscore.")
    length(name) <= 128 || fail("Nama maksimal 128 karakter.")
    String(name)
end

function database_name(raw::AbstractString)
    name = endswith(raw, ".aires") ? chop(raw; tail=6) : String(raw)
    occursin(r"^[\p{L}\p{N}_][\p{L}\p{N}_ -]*$", name) || fail("Nama database tidak valid; gunakan nama tanpa path dengan ekstensi .aires opsional.")
    name == strip(name) && length(name) <= 128 || fail("Nama database tidak valid.")
    uppercase(name) in ("CON", "PRN", "AUX", "NUL", ["COM$i" for i in 1:9]..., ["LPT$i" for i in 1:9]...) && fail("Nama database '$name' dicadangkan sistem operasi.")
    String(name)
end

function get_table(db::Database, name::String)
    haskey(db.tables, name) || fail("Tabel '$name' tidak ditemukan.")
    db.tables[name]
end
function column_index(table::Table, name::String)
    i = findfirst(c -> c.name == name, table.columns)
    i === nothing && fail("Kolom '$name' tidak ditemukan pada tabel '$(table.name)'.")
    i
end

function validate_schema(columns::Vector{ColumnDef})
    isempty(columns) && constraint("Tabel harus memiliki minimal satu kolom.")
    length(columns) <= 1024 || constraint("Tabel maksimal 1024 kolom.")
    names = Set{String}()
    for c in columns
        validate_identifier(c.name)
        c.name in names && constraint("Kolom '$(c.name)' berulang.")
        push!(names, c.name)
        c.kind in (:D,:B,:F,:I,:C,:T,:W,:TW,:U) || typeerror("Tipe '$(c.kind)' tidak dikenal.")
        c.auto && c.kind != :I && constraint("Auto_ hanya boleh digunakan pada tipe I.")
        c.primary && c.nullable && constraint("Primary Key tidak boleh NULL.")
        c.kind == :C && !(1 <= c.max_length <= 1_000_000) && constraint("Panjang C tidak valid.")
        c.kind != :C && c.max_length != 0 && constraint("Panjang hanya berlaku untuk C.")
    end
end

function validate_table(table::Table)
    validate_identifier(table.name)
    validate_schema(table.columns)
    length(table.rows) == length(table.row_ids) == length(table.row_stamps) || constraint("Metadata versi row tidak sesuai data.")
    length(unique(table.row_ids)) == length(table.row_ids) || constraint("Row ID internal berulang.")
    pk = findall(c->c.primary, table.columns)
    retain_logical = length(table.rows) <= LOGICAL_INDEX_ROW_LIMIT
    pkseen = Set{Tuple}()
    unique_indices = findall(c->c.unique, table.columns)
    unique_seen = [Set{Cell}() for _ in unique_indices]
    autos = filter(c->c.auto, table.columns)
    Set(keys(table.next_ids)) == Set(c.name for c in autos) || constraint("Metadata Auto_ tidak sesuai schema.")
    for c in autos
        1 <= table.next_ids[c.name] <= Int128(typemax(Int64))+1 || constraint("State Auto_ tidak valid.")
    end
    for row in table_rows(table)
        length(row) == length(table.columns) || constraint("Jumlah nilai tidak sesuai schema tabel '$(table.name)'.")
        for (i,c) in enumerate(table.columns)
            value = row[i]
            _valid_internal_cell(c,value) || typeerror("Representasi internal kolom '$(c.name)' tidak sesuai schema.")
            c.auto && !(value < table.next_ids[c.name]) && constraint("Nilai Auto_ tidak sesuai state sequence.")
        end
        if retain_logical && !isempty(pk)
            key = Tuple(value_key(row[i]) for i in pk)
            key in pkseen && constraint("Primary Key $(join(getfield.(table.columns[pk], :name), " + ")) harus unik; nilai $key sudah ada.")
            push!(pkseen, key)
        end
        if retain_logical
            for (n,i) in enumerate(unique_indices)
                value = value_key(row[i])
                value === nothing && continue # Multiple NULLs are allowed in nullable UNIQUE columns.
                value in unique_seen[n] && constraint("Nilai '$value' pada kolom $(table.columns[i].name) harus unik.")
                push!(unique_seen[n], value)
            end
        end
    end
    retain_logical || _validate_unique_specs_without_indexes!(table)
    nothing
end

function validate_database(db::Database)
    database_name(db.name) == db.name || constraint("Nama internal database tidak valid.")
    length(db.tables) <= 100_000 && length(db.views) <= 100_000 || constraint("Catalog melebihi batas format.")
    isempty(intersect(keys(db.tables), keys(db.views))) || constraint("Nama tabel dan view bertabrakan.")
    for (name,table) in db.tables
        name == table.name || constraint("Catalog tabel tidak konsisten.")
        length(table.rows) <= 10_000_000 || constraint("Jumlah row melebihi batas format.")
        validate_table(table)
    end
    for (name,view) in db.views
        name == view.name || constraint("Catalog view tidak konsisten.")
        validate_identifier(name)
        ncodeunits(query_text(view.query)) <= 4_000_000 || constraint("Definisi view melebihi batas format.")
        validate_query(db, view.query, Set([name]))
    end
    nothing
end
