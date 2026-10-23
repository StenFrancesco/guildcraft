local _, GGM = ...

local P = { VERSION = 1, PREFIX = "GC_BANK1", MAX_FIELD = 4096, MAX_SNAPSHOT = 40000 }
local function int(v, lo, hi) return type(v) == "number" and v == math.floor(v) and v >= lo and v <= hi end
local function str(v, max) return type(v) == "string" and #v > 0 and #v <= max and not v:find("[%z\1-\31\127]") end
local function fields(values, maxField)
    local out = {}
    for i, v in ipairs(values) do
        if type(v) ~= "string" or #v > (maxField or P.MAX_FIELD) then return nil end
        out[i] = #v .. ":" .. v
    end
    return table.concat(out)
end
local function parseFields(s, count, allowPrefix, lastMax)
    if type(s) ~= "string" or #s > P.MAX_SNAPSHOT then return nil end
    local out, at = {}, 1
    for i = 1, count do
        local colon = s:find(":", at, true); if not colon or colon - at > 5 then return nil end
        local ntext = s:sub(at, colon - 1)
        if not ntext:match("^%d+$") or (#ntext > 1 and ntext:sub(1, 1) == "0") then return nil end
        local n = tonumber(ntext); if not n or n > ((i == count and lastMax) or P.MAX_FIELD) or colon + n > #s then return nil end
        out[i] = s:sub(colon + 1, colon + n); at = colon + n + 1
    end
    if not allowPrefix and at ~= #s + 1 then return nil end
    return out
end
local function packet(kind, values)
    local all = { tostring(P.VERSION), kind }
    for _, v in ipairs(values) do all[#all + 1] = tostring(v) end
    return fields(all)
end
local schemas = { M = -1, E = 3, Q = 6, S = 0 }
function P.Encode(kind, values)
    if not schemas[kind] or type(values) ~= "table" then return nil, "bank-sync-message-invalid" end
    if kind ~= "S" then
        if kind=="M" then if #values<5 or #values>14 or (#values-5)%3~=0 then return nil,"bank-sync-message-invalid" end
        elseif #values~=schemas[kind] then return nil,"bank-sync-message-invalid" end
        local raw=packet(kind, values)
        local channel=(kind=="M" or kind=="E") and "GUILD" or "WHISPER"
        if not raw or not P.Decode(raw,channel) then return nil,"bank-sync-message-invalid" end
        return raw
    end
    if #values~=7 then return nil,"bank-sync-message-invalid" end
    local h = { tostring(P.VERSION), "S" }
    for i = 1, 6 do h[#h + 1] = tostring(values[i]) end
    local snap = values[7]
    if type(snap) ~= "table" or snap.observedSlotCount ~= 98 or snap.status ~= "cached"
        or not int(snap.id, 1, 8) or not int(snap.numSlots, 98, 98) or not int(snap.capturedAt, 0, 9007199254740991)
        or not str(snap.name, 128) or type(snap.slots) ~= "table" then return nil, "bank-sync-snapshot-invalid" end
    local ids, n = {}, 0
    for id, slot in pairs(snap.slots) do
        if not int(id, 1, 98) or type(slot) ~= "table" or not int(slot.itemID, 1, 9007199254740991)
            or not int(slot.count, 1, 9007199254740991) or not str(slot.itemLink, 1024) then return nil, "bank-sync-slot-invalid" end
        n = n + 1; ids[n] = id
    end
    table.sort(ids)
    local vals = { "98", tostring(snap.id), snap.name, "98", tostring(snap.capturedAt), "cached", tostring(n) }
    for _, id in ipairs(ids) do local slot = snap.slots[id]; vals[#vals+1]=tostring(id); vals[#vals+1]=tostring(slot.itemID); vals[#vals+1]=tostring(slot.count); vals[#vals+1]=slot.itemLink end
    local body = fields(vals, P.MAX_SNAPSHOT); if not body then return nil, "bank-sync-snapshot-invalid" end
    h[#h + 1] = body
    local encoded = fields(h, P.MAX_SNAPSHOT)
    if not encoded or #encoded > P.MAX_SNAPSHOT then return nil, "bank-sync-snapshot-too-large" end
    if not P.Decode(encoded,"WHISPER") then return nil,"bank-sync-snapshot-invalid" end
    return encoded
end
function P.Decode(raw, channel)
    if type(raw) ~= "string" or #raw > P.MAX_SNAPSHOT then return nil, "bank-sync-message-invalid" end
    local head = parseFields(raw, 2, true); if not head or head[1] ~= "1" or not schemas[head[2]] then return nil, "bank-sync-version-or-type-invalid" end
    local kind = head[2]
    if kind == "S" then
        local h = parseFields(raw, 9, false, P.MAX_SNAPSHOT); if not h or h[1] ~= "1" or h[2] ~= "S" then return nil, "bank-sync-message-invalid" end
        local b = parseFields(h[9], 7, true); if not b then return nil, "bank-sync-snapshot-invalid" end
        local count = tonumber(b[7]); if not int(count, 0, 98) then return nil, "bank-sync-snapshot-invalid" end
        local all = parseFields(h[9], 7 + count * 4); if not all then return nil, "bank-sync-snapshot-invalid" end
        local snapshot = { observedSlotCount=tonumber(all[1]), id=tonumber(all[2]), name=all[3], numSlots=tonumber(all[4]), capturedAt=tonumber(all[5]), status=all[6], slots={} }
        local last=0
        for i=1,count do local j=8+(i-1)*4; local id,item,cnt=tonumber(all[j]),tonumber(all[j+1]),tonumber(all[j+2]); if not int(id,1,98) or id<=last or not int(item,1,9007199254740991) or not int(cnt,1,9007199254740991) or not str(all[j+3],1024) then return nil,"bank-sync-slot-invalid" end; last=id; snapshot.slots[id]={itemID=item,count=cnt,itemLink=all[j+3]} end
        if snapshot.observedSlotCount~=98 or snapshot.numSlots~=98 or not int(snapshot.id,1,8) or not int(snapshot.capturedAt,0,9007199254740991) or snapshot.status~="cached" or not str(snapshot.name,128) then return nil,"bank-sync-snapshot-invalid" end
        if not str(h[3],80) or not str(h[4],160) or not str(h[5],64) or not str(h[6],64)
            or not str(h[7],32) or not int(tonumber(h[8]),1,8) or snapshot.id~=tonumber(h[8]) then return nil,"bank-sync-request-invalid" end
        local v={}; for i=3,8 do v[#v+1]=h[i] end; v[7]=snapshot
        if channel~="WHISPER" then return nil,"bank-sync-channel-invalid" end
        return { type=kind, fields=v }
    end
    local count=schemas[kind]; local f
    if kind=="M" then
        for _,n in ipairs({7,10,13,16}) do local candidate=parseFields(raw,n); if candidate then f=candidate; break end end
        if not f or (#f-7)%3~=0 then return nil,"bank-sync-fields-invalid" end
    else f=parseFields(raw,count+2) end
    if not f then return nil,"bank-sync-fields-invalid" end
    if (kind=="M" or kind=="E") and channel~="GUILD" or (kind=="Q" and channel~="WHISPER") then return nil,"bank-sync-channel-invalid" end
    local v={}; for i=3,#f do v[#v+1]=f[i] end
    if kind=="M" then
        local rows=(#v-5)/3
        if not str(v[1],80) or not str(v[2],160) or not str(v[3],64) or not int(tonumber(v[4]),1,3) or not int(tonumber(v[5]),1,3) or tonumber(v[4])>tonumber(v[5]) or rows<0 or rows>3 or rows~=math.floor(rows) then return nil,"bank-sync-manifest-invalid" end
        local seen={}; for i=6,#v,3 do local tab=tonumber(v[i]); if not int(tab,1,8) or seen[tab] then return nil,"bank-sync-manifest-invalid" end; seen[tab]=true; if v[i+1]=="-" then if v[i+2]~="-" then return nil,"bank-sync-manifest-invalid" end elseif not int(tonumber(v[i+1]),0,9007199254740991) or not v[i+2]:match("^%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$") then return nil,"bank-sync-manifest-invalid" end end
    elseif kind=="E" then if not str(v[1],80) or not str(v[2],160) or not str(v[3],64) then return nil,"bank-sync-session-invalid" end
    elseif kind=="Q" then if not str(v[1],80) or not str(v[2],160) or not str(v[3],64) or not str(v[4],64) or not str(v[5],32) or not int(tonumber(v[6]),1,8) then return nil,"bank-sync-request-invalid" end end
    return {type=kind,fields=v}
end

function P.Digest(tabID, snapshot)
    if not int(tabID,1,8) or type(snapshot)~="table" then return nil end
    local ids={}; for id in pairs(snapshot.slots or {}) do ids[#ids+1]=id end; table.sort(ids)
    local s={"B1|",tostring(tabID),"|",tostring(snapshot.capturedAt),"|"}
    for _,id in ipairs(ids) do local x=snapshot.slots[id]; s[#s+1]=table.concat({id,"|",x.itemID,"|",x.count,"|",#x.itemLink,":",x.itemLink,";"}) end
    local text=table.concat(s); local a,b=5381,17; for i=1,#text do local c=text:byte(i); a=(a*33+c)%2147483647; b=(b*65599+c)%2147483647 end
    return string.format("%08x%08x",a,b)
end

function P.BuildManifest(sender,guild,token,tabs)
    if not str(sender,80) or not str(guild,160) or not str(token,64) or type(tabs)~="table" then return nil,"bank-sync-manifest-invalid" end
    local rows={}; for id,row in pairs(tabs) do if not int(id,1,8) or type(row)~="table" then return nil,"bank-sync-manifest-invalid" end; rows[#rows+1]={id=id,row=row} end
    table.sort(rows,function(a,b)return a.id<b.id end); if #rows>8 then return nil,"bank-sync-manifest-invalid" end
    local pages={}; local total=math.max(1,math.ceil(#rows/3)); if total>3 then return nil,"bank-sync-manifest-invalid" end
    for page=1,total do
        local values={sender,guild,token,tostring(page),tostring(total)}
        for i=(page-1)*3+1,math.min(page*3,#rows) do local r=rows[i]; values[#values+1]=tostring(r.id); values[#values+1]=r.row.noComplete and "-" or tostring(r.row.capturedAt); values[#values+1]=r.row.noComplete and "-" or tostring(r.row.digest) end
        local msg=packet("M",values); if not msg or #msg>255 then return nil,"bank-sync-manifest-page-too-large" end; pages[page]=msg
    end
    return pages
end
function P.NewManifestAssembler(getTime)
    return {sets={},getTime=getTime}
end
function P.AcceptManifestPage(assembler,message,sender)
    if type(assembler)~="table" or type(message)~="table" or message.type~="M" or type(assembler.getTime)~="function" then return nil,"bank-sync-manifest-invalid" end
    local v=message.fields; if v[1]~=sender then return nil,"bank-sync-manifest-sender-mismatch" end
    local ok,now=pcall(assembler.getTime); if not ok or type(now)~="number" then return nil,"bank-sync-time-unavailable" end
    for key,set in pairs(assembler.sets) do if now-set.at>300 then assembler.sets[key]=nil end end
    local key=table.concat({sender,v[2],v[3]},"\001"); local set=assembler.sets[key]
    if not set then local n=0; for _ in pairs(assembler.sets) do n=n+1 end; if n>=8 then return nil,"bank-sync-manifest-set-limit" end; set={total=tonumber(v[5]),pages={},at=now}; assembler.sets[key]=set end
    if set.total~=tonumber(v[5]) then assembler.sets[key]=nil; return nil,"bank-sync-manifest-conflict" end
    local page=tonumber(v[4]); local rows={}; for i=6,#v,3 do rows[#rows+1]={tabID=tonumber(v[i]),capturedAt=v[i+1]=="-" and nil or tonumber(v[i+1]),digest=v[i+2]=="-" and nil or v[i+2],noComplete=v[i+1]=="-"} end
    local previous=set.pages[page]
    if previous then
        if #previous~=#rows then assembler.sets[key]=nil; return nil,"bank-sync-manifest-conflict" end
        for i,row in ipairs(rows) do local old=previous[i]; if not old or old.tabID~=row.tabID or old.capturedAt~=row.capturedAt or old.digest~=row.digest or old.noComplete~=row.noComplete then assembler.sets[key]=nil; return nil,"bank-sync-manifest-conflict" end end
        return "partial"
    end
    set.pages[page]=rows; set.at=now
    for i=1,set.total do if not set.pages[i] then return "partial" end end
    local result={sender=sender,guildKey=v[2],sessionToken=v[3],tabs={}}; for i=1,set.total do for _,row in ipairs(set.pages[i]) do if result.tabs[row.tabID] then assembler.sets[key]=nil; return nil,"bank-sync-manifest-duplicate-tab" end; result.tabs[row.tabID]=row end end
    assembler.sets[key]=nil; return result
end
GGM.BankSyncProtocol=P
