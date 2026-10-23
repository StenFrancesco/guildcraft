local _, GGM = ...
local P = GGM.BankSyncProtocol
local MAX_FRAME, CHUNK, MAX_FRAMES, MAX_ASSEMBLIES, TTL = 255, 230, 192, 8, 300
local MAX_SNAPSHOT_GROUPS, MAX_QUEUED_FRAMES, MAX_CONTROL_FRAMES = 8, 1552, 16

local function int(v, lo, hi) return type(v)=="number" and v==math.floor(v) and v>=lo and v<=hi end
local function validTarget(v) return type(v)=="string" and #v>0 and #v<=80 and not v:find("[%z\1-\31\127]") end
local pump, schedule

local function clearAll(t, reason)
    local groups={}
    for _,item in ipairs(t.queue) do groups[item.group]=true end
    if t.inFlight then groups[t.inFlight.group]=true end
    t.queue={}; t.inFlight=nil; t.snapshotTargets={}; t.snapshotGroups=0; t.controlFrames=0
    for group in pairs(groups) do
        if not group.finished then group.finished=true; if group.done then pcall(group.done,false,reason,group.target) end end
    end
end

local function clearGroup(t, group, reason)
    for i=#t.queue,1,-1 do if t.queue[i].group==group then table.remove(t.queue,i) end end
    if t.inFlight and t.inFlight.group==group then t.inFlight=nil end
    if group.target then t.snapshotTargets[group.target]=nil end
    if group.snapshot then t.snapshotGroups=math.max(0,t.snapshotGroups-1) else t.controlFrames=math.max(0,t.controlFrames-group.frames) end
    if group.done and not group.finished then group.finished=true; pcall(group.done,false,reason,group.target) end
    t.lastSendError=reason
    if #t.queue>0 and not t.timer and not t.inFlight and not schedule(t) then clearAll(t,"bank-sync-timer-failed") end
end

schedule=function(t)
    local generation=t.generation
    local ok,timer=pcall(t.api.C_Timer.NewTimer,0,function() if generation==t.generation then t.timer=nil; pump(t) end end)
    if not ok or not timer then return false end
    t.timer=timer
    return true
end

pump=function(t)
    if t.closed or t.timer or t.inFlight then return end
    local item=t.queue[1]; if not item then return end
    t.inFlight=item
    local called=false
    local function cb(_,success,result)
        if called or t.closed or t.inFlight~=item then return end
        called=true; t.inFlight=nil
        if success~=true and result~=0 then clearGroup(t,item.group,"bank-sync-send-failed"); return end
        table.remove(t.queue,1); item.group.left=item.group.left-1
        if not item.group.snapshot then t.controlFrames=math.max(0,t.controlFrames-1); item.group.frames=math.max(0,item.group.frames-1) end
        if item.group.left==0 then
            local group=item.group; group.finished=true
            if group.target then t.snapshotTargets[group.target]=nil end
            if group.snapshot then t.snapshotGroups=math.max(0,t.snapshotGroups-1) end
            if group.done then pcall(group.done,true,nil,group.target) end
        end
        if #t.queue>0 and not schedule(t) then clearAll(t,"bank-sync-timer-failed") end
    end
    local ok=pcall(t.api.ChatThrottleLib.SendAddonMessage,t.api.ChatThrottleLib,"BULK",P.PREFIX,item.frame,item.group.channel,item.group.target,P.PREFIX,cb)
    if not ok and not called then clearGroup(t,item.group,"bank-sync-send-error") end
end

local function encoded(payload)
    if #payload>P.MAX_SNAPSHOT then return nil end
    local lib=LibStub and LibStub:GetLibrary("LibDeflate",true)
    if not lib or type(GGM.DecompressProfessionDeflate)~="function" then return nil end
    local ok,value=pcall(function() return "B1|"..#payload.."|"..lib:Adler32(payload).."|"..lib:EncodeForWoWAddonChannel(lib:CompressDeflate(payload,{level=1})) end)
    if not ok or type(value)~="string" then return nil end
    return value
end

local function decodePayload(payload)
    local lib=LibStub and LibStub:GetLibrary("LibDeflate",true)
    if not lib or #payload>CHUNK*MAX_FRAMES then return nil end
    local lenText,sumText,start=payload:match("^B1|(%d+)|(%d+)|()")
    local length,checksum=tonumber(lenText),tonumber(sumText)
    if not length or #lenText>5 or length<1 or length>P.MAX_SNAPSHOT or not checksum or #sumText>10 or checksum>4294967295 then return nil end
    local ok,value=pcall(function()
        local compressed=lib:DecodeForWoWAddonChannel(payload:sub(start)); if not compressed then return nil end
        local decoded,remaining=GGM.DecompressProfessionDeflate(compressed,length)
        if remaining~=0 or type(decoded)~="string" or #decoded~=length or lib:Adler32(decoded)~=checksum then return nil end
        return decoded
    end)
    if not ok or type(value)~="string" then return nil end
    return value
end

local function makeFrames(t,payload)
    local bytes=encoded(payload); if not bytes or #bytes>CHUNK*MAX_FRAMES then return nil,"bank-sync-payload-too-large" end
    local total=math.ceil(#bytes/CHUNK); if total<1 or total>MAX_FRAMES then return nil,"bank-sync-frame-count-invalid" end
    t.nextID=t.nextID%999999+1
    local id=string.format("%06d",t.nextID); local frames={}
    for i=1,total do
        local frame=string.format("F1|%s|%03d|%03d|%s",id,i,total,bytes:sub((i-1)*CHUNK+1,i*CHUNK))
        if #frame>MAX_FRAME then return nil,"bank-sync-frame-too-large" end
        frames[i]=frame
    end
    return frames
end

function GGM.CreateBankSyncTransport(api,onMessage,onFailure)
    if type(api)~="table" or type(api.C_ChatInfo)~="table" or type(api.C_ChatInfo.RegisterAddonMessagePrefix)~="function"
        or type(api.ChatThrottleLib)~="table" or type(api.ChatThrottleLib.SendAddonMessage)~="function"
        or type(api.C_Timer)~="table" or type(api.C_Timer.NewTimer)~="function" or type(api.GetTime)~="function"
        or type(onMessage)~="function" then return nil,"bank-sync-transport-api-unavailable" end
    local lib=LibStub and LibStub:GetLibrary("LibDeflate",true)
    if not lib or not lib.EncodeForWoWAddonChannel or not lib.DecodeForWoWAddonChannel or not lib.CompressDeflate or not lib.Adler32 or type(GGM.DecompressProfessionDeflate)~="function" then return nil,"bank-sync-compression-unavailable" end
    return {api=api,onMessage=onMessage,onFailure=onFailure,queue={},assemblies={},nextID=0,snapshotTargets={},snapshotGroups=0,controlFrames=0,generation=0},nil
end

function GGM.SetBankSyncTransportIdentity(t,senderKey,sessionToken)
    if type(t)~="table" or type(senderKey)~="string" or #senderKey==0 or #senderKey>80 or type(sessionToken)~="string" or #sessionToken==0 or #sessionToken>64 then return false,"bank-sync-identity-invalid" end
    t.senderKey=senderKey; t.sessionToken=sessionToken
    return true
end

function GGM.RegisterBankSyncTransport(t)
    if not t or t.closed then return false,"bank-sync-transport-unavailable" end
    local ok,result=pcall(t.api.C_ChatInfo.RegisterAddonMessagePrefix,P.PREFIX)
    return ok and (result==0 or result==true),ok and "bank-sync-prefix-register-failed" or "bank-sync-prefix-register-error"
end

function GGM.SendBankSyncMessage(t,kind,values,target,channel,done)
    if not t or t.closed then return false,"bank-sync-transport-unavailable" end
    local canonical=(kind=="M" or kind=="E") and "GUILD" or (kind=="Q" and "WHISPER" or nil)
    if not canonical or (channel~=nil and channel~=canonical) or (canonical=="GUILD" and target~=nil) or (canonical=="WHISPER" and not validTarget(target)) then return false,"bank-sync-distribution-invalid" end
    local payload,err=P.Encode(kind,values); if not payload then return false,err end
    local frames; frames,err=makeFrames(t,payload); if not frames then return false,err end
    if t.controlFrames+#frames>MAX_CONTROL_FRAMES or #t.queue+#frames>MAX_QUEUED_FRAMES then
        if done then pcall(done,false,"bank-sync-outbound-limit",target) end
        return false,"bank-sync-outbound-limit"
    end
    local group={target=target,channel=canonical,left=#frames,frames=#frames,done=done}
    t.controlFrames=t.controlFrames+#frames
    for _,frame in ipairs(frames) do t.queue[#t.queue+1]={frame=frame,group=group} end
    pump(t)
    return true,nil,group
end

function GGM.SendBankSyncSnapshot(t,target,requestValues,snapshot,done)
    if not t or t.closed then return false,"bank-sync-transport-unavailable" end
    if not validTarget(target) or type(requestValues)~="table" or #requestValues~=6 or not t.senderKey or not t.sessionToken or requestValues[4]~=t.sessionToken then
        if done then pcall(done,false,"bank-sync-snapshot-sender-invalid",target) end
        return false,"bank-sync-snapshot-sender-invalid"
    end
    if t.snapshotTargets[target] then if done then pcall(done,false,"bank-sync-snapshot-queue-busy",target) end; return false,"bank-sync-snapshot-queue-busy" end
    if t.snapshotGroups>=MAX_SNAPSHOT_GROUPS then if done then pcall(done,false,"bank-sync-outbound-limit",target) end; return false,"bank-sync-outbound-limit" end
    -- The response identifies this sender, while preserving the request's
    -- guild, both session tokens, request ID, and tab ID.
    local values={t.senderKey,requestValues[2],requestValues[3],requestValues[4],requestValues[5],requestValues[6],snapshot}
    local payload,err=P.Encode("S",values); if not payload then return false,err end
    local frames; frames,err=makeFrames(t,payload); if not frames then return false,err end
    if #t.queue+#frames>MAX_QUEUED_FRAMES then if done then pcall(done,false,"bank-sync-outbound-limit",target) end; return false,"bank-sync-outbound-limit" end
    local group={target=target,channel="WHISPER",left=#frames,frames=#frames,snapshot=true,done=done}
    t.snapshotTargets[target]=group; t.snapshotGroups=t.snapshotGroups+1
    for _,frame in ipairs(frames) do t.queue[#t.queue+1]={frame=frame,group=group} end
    pump(t)
    return true,nil,group
end

function GGM.CancelBankSyncTransport(t,reason)
    if type(t)~="table" then return false,"bank-sync-transport-unavailable" end
    t.generation=t.generation+1
    local timer=t.timer; t.timer=nil
    if type(timer)=="table" and type(timer.Cancel)=="function" then pcall(timer.Cancel,timer) end
    -- This clears only addon-owned work. CTL cannot retract its one submitted
    -- frame; the controller must reject any stale completed response by session/request.
    t.assemblies={}; clearAll(t,reason or "bank-sync-send-cancelled")
    return true
end

local function cleanup(t,now) for key,assembly in pairs(t.assemblies) do if now-assembly.at>TTL then t.assemblies[key]=nil end end end
function GGM.ReceiveBankSyncFrame(t,prefix,text,channel,sender,validateResponse)
    if prefix~=P.PREFIX then return "ignored" end
    if type(text)~="string" or #text>MAX_FRAME or type(sender)~="string" or #sender==0 or #sender>80 or (channel~="GUILD" and channel~="WHISPER") then return nil,"bank-sync-frame-invalid" end
    local id,ix,totalText,start=text:match("^F1|(%d%d%d%d%d%d)|(%d%d%d)|(%d%d%d)|()")
    local index,total=tonumber(ix),tonumber(totalText)
    if not id or id=="000000" or not int(index,1,MAX_FRAMES) or not int(total,1,MAX_FRAMES) or index>total then return nil,"bank-sync-frame-invalid" end
    local chunk=text:sub(start); if #chunk<1 or #chunk>CHUNK then return nil,"bank-sync-chunk-invalid" end
    local now=t.api.GetTime(); cleanup(t,now)
    local key=sender.."|"..channel.."|"..id; local assembly=t.assemblies[key]
    if not assembly then
        local count=0; for _ in pairs(t.assemblies) do count=count+1 end
        if count>=MAX_ASSEMBLIES then return nil,"bank-sync-assembly-limit" end
        assembly={n=total,parts={},count=0,bytes=0,at=now}; t.assemblies[key]=assembly
    elseif assembly.n~=total then t.assemblies[key]=nil; return nil,"bank-sync-frame-conflict" end
    if assembly.parts[index] then if assembly.parts[index]~=chunk then t.assemblies[key]=nil; return nil,"bank-sync-frame-conflict" end; return "partial" end
    assembly.parts[index]=chunk; assembly.count=assembly.count+1; assembly.bytes=assembly.bytes+#chunk; assembly.at=now
    if assembly.bytes>CHUNK*MAX_FRAMES then t.assemblies[key]=nil; return nil,"bank-sync-payload-too-large" end
    if assembly.count<total then return "partial" end
    local payload=decodePayload(table.concat(assembly.parts)); t.assemblies[key]=nil
    if not payload then return nil,"bank-sync-decode-failed" end
    local message,err=P.Decode(payload,channel); if not message then return nil,err end
    if message.type=="S" then
        if type(validateResponse)~="function" then return nil,"bank-sync-response-unbound" end
        local ok,valid=pcall(validateResponse,sender,message.fields)
        if not ok or valid~=true then return nil,"bank-sync-response-unbound" end
    end
    local ok,state,handlerErr=pcall(t.onMessage,message,sender,channel)
    if not ok then return nil,"bank-sync-handler-failed" end
    return state or "complete",handlerErr
end

GGM.BankSyncTransportConstants={MAX_FRAME=MAX_FRAME,CHUNK=CHUNK,MAX_FRAMES=MAX_FRAMES,TTL=TTL,MAX_SNAPSHOT_GROUPS=MAX_SNAPSHOT_GROUPS,MAX_QUEUED_FRAMES=MAX_QUEUED_FRAMES}
