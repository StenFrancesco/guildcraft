local _, GGM = ...
local P = GGM.BankSyncProtocol
local MAX_FRAME, CHUNK, MAX_FRAMES, MAX_ASSEMBLIES, TTL = 255, 230, 192, 8, 300
local function int(v, lo, hi) return type(v)=="number" and v==math.floor(v) and v>=lo and v<=hi end
local function clearGroup(t, group, err)
    for i=#t.queue,1,-1 do if t.queue[i].group==group then table.remove(t.queue,i) end end
    if t.inFlight and t.inFlight.group==group then t.inFlight=nil end
    t.snapshotTargets[group.target]=nil
    if group.done then pcall(group.done,false,err,group.target) end
    t.lastSendError=err
end
local pump
local function schedule(t)
    local generation=t.generation
    local ok,timer=pcall(t.api.C_Timer.NewTimer,0,function() if generation==t.generation then t.timer=nil; pump(t) end end)
    if not ok or not timer then return false end; t.timer=timer; return true
end
pump=function(t)
    if t.closed or t.timer or t.inFlight then return end
    local item=t.queue[1]; if not item then return end
    t.inFlight=item
    local called=false
    local function cb(_,success,result)
        if called or t.closed or t.inFlight~=item then return end; called=true; t.inFlight=nil
        if success~=true and result~=0 then clearGroup(t,item.group,"bank-sync-send-failed"); return end
        table.remove(t.queue,1); item.group.left=item.group.left-1
        if item.group.left==0 then t.snapshotTargets[item.group.target]=nil; if item.group.done then pcall(item.group.done,true,nil,item.group.target) end end
        if #t.queue>0 and not schedule(t) then clearGroup(t,item.group,"bank-sync-timer-failed") end
    end
    local ok=pcall(t.api.ChatThrottleLib.SendAddonMessage,t.api.ChatThrottleLib,"BULK",P.PREFIX,item.frame,item.group.channel,item.group.target,P.PREFIX,cb)
    if not ok and not called then clearGroup(t,item.group,"bank-sync-send-error") end
end
local function encoded(payload)
    if #payload>P.MAX_SNAPSHOT then return nil end
    local lib=LibStub and LibStub:GetLibrary("LibDeflate",true); if not lib then return nil end
    if type(GGM.DecompressProfessionDeflate)~="function" then return nil end
    local ok,value=pcall(function() return "B1|"..#payload.."|"..lib:Adler32(payload).."|"..lib:EncodeForWoWAddonChannel(lib:CompressDeflate(payload,{level=1})) end)
    if not ok or type(value)~="string" then return nil end; return value
end
local function decodePayload(payload)
    local lib=LibStub and LibStub:GetLibrary("LibDeflate",true); if not lib then return nil end
    if #payload>CHUNK*MAX_FRAMES then return nil end
    local lenText,sumText,start=payload:match("^B1|(%d+)|(%d+)|()")
    local length,checksum=tonumber(lenText),tonumber(sumText)
    if not length or #lenText>5 or length<1 or length>P.MAX_SNAPSHOT or not checksum or #sumText>10 or checksum>4294967295 then return nil end
    local ok,value=pcall(function() local compressed=lib:DecodeForWoWAddonChannel(payload:sub(start)); if not compressed then return nil end; local decoded,remaining=GGM.DecompressProfessionDeflate(compressed,length); if remaining~=0 or type(decoded)~="string" or #decoded~=length or lib:Adler32(decoded)~=checksum then return nil end; return decoded end)
    if not ok or type(value)~="string" then return nil end; return value
end
local function makeFrames(t,payload)
    local bytes=encoded(payload); if not bytes or #bytes>CHUNK*MAX_FRAMES then return nil,"bank-sync-payload-too-large" end
    local total=math.ceil(#bytes/CHUNK); if total<1 or total>MAX_FRAMES then return nil,"bank-sync-frame-count-invalid" end
    t.nextID=t.nextID%999999+1; local id=string.format("%06d",t.nextID); local frames={}
    for i=1,total do local f=string.format("F1|%s|%03d|%03d|%s",id,i,total,bytes:sub((i-1)*CHUNK+1,i*CHUNK)); if #f>MAX_FRAME then return nil,"bank-sync-frame-too-large" end; frames[i]=f end
    return frames
end
function GGM.CreateBankSyncTransport(api,onMessage,onFailure)
    if type(api)~="table" or type(api.C_ChatInfo)~="table" or type(api.C_ChatInfo.RegisterAddonMessagePrefix)~="function" or type(api.ChatThrottleLib)~="table" or type(api.ChatThrottleLib.SendAddonMessage)~="function" or type(api.C_Timer)~="table" or type(api.C_Timer.NewTimer)~="function" or type(api.GetTime)~="function" or type(onMessage)~="function" then return nil,"bank-sync-transport-api-unavailable" end
    local lib=LibStub and LibStub:GetLibrary("LibDeflate",true); if not lib or not lib.EncodeForWoWAddonChannel or not lib.DecodeForWoWAddonChannel or not lib.CompressDeflate or not lib.Adler32 or type(GGM.DecompressProfessionDeflate)~="function" then return nil,"bank-sync-compression-unavailable" end
    return {api=api,onMessage=onMessage,onFailure=onFailure,queue={},assemblies={},nextID=0,snapshotTargets={},generation=0},nil
end
function GGM.RegisterBankSyncTransport(t)
    if not t or t.closed then return false,"bank-sync-transport-unavailable" end
    local ok,result=pcall(t.api.C_ChatInfo.RegisterAddonMessagePrefix,P.PREFIX); return ok and (result==0 or result==true), ok and "bank-sync-prefix-register-failed" or "bank-sync-prefix-register-error"
end
function GGM.SendBankSyncMessage(t,kind,values,target,channel,done)
    if not t or t.closed then return false,"bank-sync-transport-unavailable" end
    local raw,err=P.Encode(kind,values); if not raw then return false,err end
    local frames; frames,err=makeFrames(t,raw); if not frames then return false,err end
    local group={target=target,channel=channel or (target and "WHISPER" or "GUILD"),left=#frames,done=done}
    for _,frame in ipairs(frames) do t.queue[#t.queue+1]={frame=frame,group=group} end; pump(t); return true,nil,group
end
function GGM.SendBankSyncSnapshot(t,target,requestValues,snapshot,done)
    if t.snapshotTargets[target] then return false,"bank-sync-snapshot-queue-busy" end
    local values={}; for i=1,6 do values[i]=requestValues[i] end; values[7]=snapshot
    local raw,err=P.Encode("S",values); if not raw then return false,err end
    t.snapshotTargets[target]=true
    local frames; frames,err=makeFrames(t,raw); if not frames then t.snapshotTargets[target]=nil; return false,err end
    local group={target=target,channel="WHISPER",left=#frames,done=done}; t.snapshotTargets[group.target]=group
    for _,frame in ipairs(frames) do t.queue[#t.queue+1]={frame=frame,group=group} end; pump(t); return true,nil,group
end
local function cleanup(t,now) for key,a in pairs(t.assemblies) do if now-a.at>TTL then t.assemblies[key]=nil end end end
function GGM.ReceiveBankSyncFrame(t,prefix,text,channel,sender,validateResponse)
    if prefix~=P.PREFIX then return "ignored" end
    if type(text)~="string" or #text>MAX_FRAME or type(sender)~="string" or #sender==0 or #sender>80 or (channel~="GUILD" and channel~="WHISPER") then return nil,"bank-sync-frame-invalid" end
    local id,ix,tot,start=text:match("^F1|(%d%d%d%d%d%d)|(%d%d%d)|(%d%d%d)|()")
    local i,n=tonumber(ix),tonumber(tot); if not id or id=="000000" or not int(i,1,MAX_FRAMES) or not int(n,1,MAX_FRAMES) or i>n then return nil,"bank-sync-frame-invalid" end
    local chunk=text:sub(start); if #chunk<1 or #chunk>CHUNK then return nil,"bank-sync-chunk-invalid" end
    local now=t.api.GetTime(); cleanup(t,now); local key=sender.."|"..channel.."|"..id; local a=t.assemblies[key]
    if not a then local c=0; for _ in pairs(t.assemblies) do c=c+1 end; if c>=MAX_ASSEMBLIES then return nil,"bank-sync-assembly-limit" end; a={n=n,parts={},count=0,bytes=0,at=now}; t.assemblies[key]=a elseif a.n~=n then t.assemblies[key]=nil; return nil,"bank-sync-frame-conflict" end
    if a.parts[i] then if a.parts[i]~=chunk then t.assemblies[key]=nil; return nil,"bank-sync-frame-conflict" end; return "partial" end
    a.parts[i]=chunk;a.count=a.count+1;a.bytes=a.bytes+#chunk;a.at=now;if a.bytes>CHUNK*MAX_FRAMES then t.assemblies[key]=nil;return nil,"bank-sync-payload-too-large" end;if a.count<n then return "partial" end
    local payload=decodePayload(table.concat(a.parts));t.assemblies[key]=nil;if not payload then return nil,"bank-sync-decode-failed" end
    local msg,err=P.Decode(payload,channel);if not msg then return nil,err end
    if msg.type=="S" then if type(validateResponse)~="function" then return nil,"bank-sync-response-unbound" end; local ok,valid=pcall(validateResponse,sender,msg.fields);if not ok or valid~=true then return nil,"bank-sync-response-unbound" end end
    local ok,state,handlerErr=pcall(t.onMessage,msg,sender,channel);if not ok then return nil,"bank-sync-handler-failed" end;return state or "complete",handlerErr
end
GGM.BankSyncTransportConstants={MAX_FRAME=MAX_FRAME,CHUNK=CHUNK,MAX_FRAMES=MAX_FRAMES,TTL=TTL}
