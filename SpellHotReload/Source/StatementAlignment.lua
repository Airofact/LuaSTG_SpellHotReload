-- Ordered source evidence only; never runtime identity or permission to publish.
-- Unique exact signatures anchor unchanged regions. Repeated unanchored regions
-- stay ambiguous; reordering is reported and never treated as an equal file.
local M={}
function M.Compare(before,after)
    local result={equal=true,changes={},matches={},ambiguous=false}
    local stack={{1,#before,1,#after}}
    local function same(a,b) return before[a].signature==after[b].signature end
    local function change(a,z,b,y,ambiguous)
        local old,new={},{}
        for i=a,z do old[#old+1]=before[i] end
        for i=b,y do new[#new+1]=after[i] end
        result.equal=false;result.ambiguous=result.ambiguous or ambiguous
        result.changes[#result.changes+1]={kind=#old==0 and "insert" or #new==0 and "delete" or "replace",
            before=old,after=new,ambiguous=ambiguous}
    end
    while #stack>0 do
        local region=table.remove(stack)
        local a,z,b,y=unpack(region)
        local equal=z-a==y-b
        if equal then for k=0,z-a do if not same(a+k,b+k) then equal=false;break end end end
        if equal then
            -- These are equal text-sequence positions, not cross-version owners.
            for k=0,z-a do result.matches[#result.matches+1]={before=before[a+k],after=after[b+k]} end
        elseif a>z or b>y then change(a,z,b,y,false)
        else
            local left,right={},{}
            for i=a,z do local key=before[i].signature;left[key]=left[key] and 0 or i end
            for i=b,y do local key=after[i].signature;right[key]=right[key] and 0 or i end
            local pairs,tails,previous={}, {},{}
            for i=a,z do
                local key=before[i].signature
                local j=right[key]
                if left[key]==i and j and j>0 then
                    pairs[#pairs+1]={i,j}
                    local lo,hi=1,#tails+1
                    while lo<hi do local mid=math.floor((lo+hi)/2);if pairs[tails[mid]][2]<j then lo=mid+1 else hi=mid end end
                    previous[#pairs]=lo>1 and tails[lo-1] or nil;tails[lo]=#pairs
                end
            end
            if #tails==0 then
                local overlap=false
                for key in next,left do if right[key]~=nil then overlap=true;break end end
                change(a,z,b,y,overlap)
            else
                local anchors,at={},tails[#tails]
                while at do anchors[#anchors+1]=pairs[at];at=previous[at] end
                local x,w=a,b
                for k=#anchors,1,-1 do
                    local anchor=anchors[k]
                    stack[#stack+1]={x,anchor[1]-1,w,anchor[2]-1}
                    result.matches[#result.matches+1]={before=before[anchor[1]],after=after[anchor[2]]}
                    x,w=anchor[1]+1,anchor[2]+1
                end
                stack[#stack+1]={x,z,w,y}
            end
        end
    end
    -- A unique shared signature displaced by the monotone anchors is a reorder.
    local old,new={},{}
    for _,c in ipairs(result.changes) do
        for _,row in ipairs(c.before) do old[row.signature]=true end
        for _,row in ipairs(c.after) do new[row.signature]=true end
    end
    local old_count,new_count={},{}
    for _,row in ipairs(before) do old_count[row.signature]=(old_count[row.signature] or 0)+1 end
    for _,row in ipairs(after) do new_count[row.signature]=(new_count[row.signature] or 0)+1 end
    result.reordered=false
    for key in next,old do
        if new[key] and old_count[key]==1 and new_count[key]==1 then result.reordered=true;break end
    end
    table.sort(result.changes,function(x,y)
        local a=(x.after[1] or x.before[1]).first
        local b=(y.after[1] or y.before[1]).first
        return a<b
    end)
    return result
end
return M
