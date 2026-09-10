# SPDX-FileCopyrightText: 2026 Aires Zam Wibisono
# SPDX-License-Identifier: NCSA

"""A diagnostic intended for an AiresQL user rather than a Julia stack trace."""
struct AiresError <: Exception
    category::String
    message::String
end
Base.showerror(io::IO, e::AiresError) = print(io, e.category, ":\n", e.message)
fail(message) = throw(AiresError("AiresQL Error", message))
syntaxerror(message) = throw(AiresError("AiresQL Syntax Error", message))
constraint(message) = throw(AiresError("Constraint Error", message))
typeerror(message) = throw(AiresError("Type Error", message))
storageerror(message) = throw(AiresError("Storage Error", message))
