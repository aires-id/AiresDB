# SPDX-FileCopyrightText: 2026 Aires Zam Wibisono
# SPDX-License-Identifier: NCSA

struct Token
    kind::Symbol
    text::String
    offset::Int
    line::Int
    column::Int
end

const PUNCTUATION = Dict('('=>:lparen, ')'=>:rparen, '.'=>:dot, ','=>:comma,
    '+'=>:plus, '-'=>:minus, '*'=>:star, '/'=>:slash, '='=>:eq, '>'=>:gt, '<'=>:lt)
