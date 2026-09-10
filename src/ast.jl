# SPDX-FileCopyrightText: 2026 Aires Zam Wibisono
# SPDX-License-Identifier: NCSA

abstract type ExprNode end
struct Literal <: ExprNode
    value::Cell
end
struct ColumnRef <: ExprNode
    table::Union{Nothing,String}
    name::String
end
"""Transient execution node; never persisted. Resolves a column once per query."""
struct BoundRef <: ExprNode
    index::Int
end
struct Wildcard <: ExprNode end
struct UnaryExpr <: ExprNode
    op::Symbol
    operand::ExprNode
end
struct BinaryExpr <: ExprNode
    op::Symbol
    left::ExprNode
    right::ExprNode
end
"""Three-valued logical conjunction in an AiresQL condition."""
struct LogicalAnd <: ExprNode
    left::ExprNode
    right::ExprNode
end
"""Three-valued logical disjunction in an AiresQL condition."""
struct LogicalOr <: ExprNode
    left::ExprNode
    right::ExprNode
end
struct CallExpr <: ExprNode
    name::Symbol
    args::Vector{ExprNode}
end

@enum SortDirection::UInt8 SortAscending SortDescending
struct OrderByItem
    expression::ExprNode
    direction::SortDirection
end
"""Parsed `M:` clause; its items are retained by `SelectQuery.orders`."""
struct OrderByClause
    items::Vector{OrderByItem}
end

abstract type Statement end
struct CreateDatabase <: Statement; name::String; end
struct UseDatabase <: Statement; name::String; end
struct CreateTable <: Statement
    name::String
    columns::Vector{ColumnDef}
end
struct InsertRows <: Statement
    table::String
    values::Vector{Vector{String}}
end
struct SelectQuery <: Statement
    expressions::Vector{ExprNode}
    labels::Vector{String}
    sources::Vector{String}
    condition::Union{Nothing,ExprNode}
    join_condition::Union{Nothing,ExprNode}
    groups::Vector{ExprNode}
    orders::Vector{OrderByItem}
    limit::Union{Nothing,Int}
end
"""Compatibility constructor for queries created before the `M:` clause existed."""
SelectQuery(expressions, labels, sources, condition, join_condition, groups, limit) =
    SelectQuery(expressions, labels, sources, condition, join_condition, groups, OrderByItem[], limit)
struct Assignment
    column::String
    expression::ExprNode
end
struct UpdateRows <: Statement
    table::String
    assignments::Vector{Assignment}
    condition::Union{Nothing,ExprNode}
end
struct AddColumn <: Statement; table::String; column::ColumnDef; end
struct RemoveColumn <: Statement; table::String; column::String; end
struct DeleteRows <: Statement
    table::String
    condition::Union{Nothing,ExprNode}
end
struct DropTable <: Statement; table::String; end
struct CreateView <: Statement; name::String; query::SelectQuery; end
struct TransactionCommand <: Statement; action::Symbol; end
