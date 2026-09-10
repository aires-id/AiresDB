# SPDX-FileCopyrightText: 2026 Aires Zam Wibisono
# SPDX-License-Identifier: NCSA

"""Persistent physical row identity: page ID plus stable slot ID."""
struct RID
    page_id::UInt64
    slot_id::UInt16
    function RID(page_id::Integer,slot_id::Integer)
        1 <= page_id <= typemax(UInt64) || storageerror("RID page ID tidak valid.")
        1 <= slot_id <= typemax(UInt16) || storageerror("RID slot ID tidak valid.")
        new(UInt64(page_id),UInt16(slot_id))
    end
end

Base.isless(left::RID,right::RID) = left.page_id == right.page_id ? left.slot_id < right.slot_id : left.page_id < right.page_id
function Base.show(io::IO,rid::RID)
    print(io,"RID(",rid.page_id,",",rid.slot_id,")")
end
