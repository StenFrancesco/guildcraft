local T = require('tests.testlib')
local function fixture(owners, recipeCount)
    local G = {CPUManualDriver=true}
    for _,name in ipairs({'Constants','CPUWork','ProfessionSnapshot','ProfessionIndex','Storage','ProfessionSyncData','SnapshotTestUI','ProfessionRosterWork'}) do
        T.loadAddonFile('The Guild Book/'..name..'.lua',G)
    end
    local db=assert(G.InitializeDatabase(nil)); G.professionRosterMembershipCurrent=true
    for i=1,owners do
        local guid,key='Player-1-'..i,'Crafter'..i..'-Realm'
        db.professionCharacters[i]={guid=guid,key=key,active=true};db.localCharacterIDByGUID[guid]=i
        db.professions[key]={identity={guid=guid,key=key,name='Crafter'..i,realm='Realm'},snapshots={
            [164]={professionID=164,professionName='Blacksmithing',complete=true,capturedAt=1700000000,
                source=G.PROFESSION_SOURCE_GUILD_LINK,status='cached'}}}
    end
    db.nextLocalCharacterID=owners+1;db.professionRecipeIndex[164]={}
    for id=1,recipeCount do
        local ids={};for i=1,owners do ids[i]=i end
        db.professionRecipeIndex[164][id]={name='Recipe '..id,crafters=ids}
    end
    return G,db
end
local api={debugprofilestop=function() return os.clock()*1000 end,date=os.date}
local function run(owners,recipes)
    local G,db=fixture(owners,recipes)
    collectgarbage('collect')
    local completed,frames,total,maximum,over1,over2={},0,0,0,0,0
    local function job(name,build)
        G.StartCPUJob(name,build,function(value) completed[name]=value end,{api=api})
    end
    job('digest',function() return G.GetProfessionSyncDigest(db,164) end)
    job('catalog',function() return G.BuildProfessionRecipeCatalog(db,164,'Blacksmithing',api) end)
    while G.GetCPUJobCount()>0 do
        local started=os.clock();G.RunCPUFrame();local elapsed=(os.clock()-started)*1000
        frames,total,maximum=frames+1,total+elapsed,math.max(maximum,elapsed)
        if elapsed>1.01 then over1=over1+1 end;if elapsed>2.01 then over2=over2+1 end
        assert(frames<200000,'unbounded work')
    end
    assert(completed.digest and completed.catalog.state=='ready' and #completed.catalog.recipes==recipes)
    local expected=G.GetProfessionSyncDigest(db,164);assert(expected==completed.digest)
    job('filter',function() return G.FilterProfessionRecipeBrowserEntries(completed.catalog.recipes,'Recipe 1') end)
    local filterFrames,filterMax=0,0
    while G.GetCPUJobCount()>0 do
        local started=os.clock();G.RunCPUFrame();filterMax=math.max(filterMax,(os.clock()-started)*1000);filterFrames=filterFrames+1
    end
    assert(#completed.filter>0)
    local started=os.clock();assert(G.EnsureProfessionIndex(db,true));local validation=(os.clock()-started)*1000
    local identity=db.professions['Crafter1-Realm'].identity
    local capture=assert(G.GetProfessionSyncRecord(db,identity.guid,164))
    started=os.clock();assert(G.SaveProfessionSnapshot(db,identity,capture,{guildMembershipVerified=true}));local save=(os.clock()-started)*1000
    local token=assert(G.PrepareProfessionValidationOperation(db,identity))
    started=os.clock();assert(G.SaveProfessionSnapshot(db,identity,capture,{guildMembershipVerified=true,indexValidationOperation=token}));local preparedSave=(os.clock()-started)*1000
    local roster={}
    for _,member in pairs(db.professionCharacters) do roster[#roster+1]=member end
    local rosterAPI=setmetatable({
        IsInGuild=function() return true end,
        GetNumGuildMembers=function() return #roster end,
        GetRealmName=function() return 'Realm' end,
        GetGuildRosterInfo=function(index)
            local row=roster[index]
            return row.key,nil,nil,nil,nil,nil,nil,nil,true,nil,nil,nil,nil,nil,nil,nil,row.guid
        end,
    },{__index=api})
    local rosterResult
    assert(G.QueueProfessionRosterReconciliation(rosterAPI,db,function(ok,err,changed)
        assert(ok,err);assert(changed==false);rosterResult=true
    end))
    local rosterFrames,rosterMax=0,0
    while G.GetCPUJobCount()>0 do
        local started=os.clock();G.RunCPUFrame();rosterMax=math.max(rosterMax,(os.clock()-started)*1000);rosterFrames=rosterFrames+1
        assert(rosterFrames<100000)
    end
    assert(rosterResult)
    print(string.format('%dx%d combined: frames=%d total=%.3fms max=%.3fms >1ms=%d >2ms=%d; filter frames=%d max=%.3fms; sync fullValidation=%.3fms save=%.3fms preparedCommit=%.3fms; roster frames=%d max=%.3fms',
        owners,recipes,frames,total,maximum,over1,over2,filterFrames,filterMax,validation,save,preparedSave,rosterFrames,rosterMax))
end
print(_VERSION..'; CPU ms using os.clock (~1 ms resolution); normal GC; setup/forced GC excluded; combined digest+catalog')
for sample=1,tonumber(arg[1]) or 5 do
    print('sample '..sample)
    for _,size in ipairs({{10,500},{50,1000},{100,2000},{250,4096}}) do run(size[1],size[2]) end
end
