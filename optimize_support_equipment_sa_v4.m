function result = optimize_support_equipment_sa_v4( ...
    shipIDs, ExSlotAvailable, EquipmentInventory, HitrateOptions, ...
    EnemyData, EnemyWeights, ObjectiveWeights, varargin)
%OPTIMIZE_SUPPORT_EQUIPMENT_SA_V4
% Fast simulated-annealing optimizer for support-shelling equipment.
% 
% ExSlotAvailable must be a 6-element logical/numeric vector. A true value
% enables the expansion slot for the corresponding ship.
%
% Expansion-slot candidates are restricted by BOTH:
%   1) the ship-specific feasibility in the v2 compatibility workbook
%      (ExpansionItemLookup sheet), and
%   2) enforced support-shelling expansion-slot categories:
%        FBB : any radar, 三式弾 / 三式弾改 / 三式弾改二, 水上艦要員
%        CVL/B: 航空要員 or any radar
%        DD  : any radar, 小口径主砲, 水上艦要員
%
% Name/value option of particular interest:
%   'UseParfor' : false by default. If true, independent SA starts are
%                 evaluated with PARFOR. Parallel Computing Toolbox is
%                 required.
%
% Objective:
%   Maximize the expected weighted damage-state score over:
%     - all six support ships,
%     - all enemies, with uniform targeting probability,
%     - all four engagement formations.
%
%   J = sum_s sum_e (Weight_e / N_enemy) *
%           sum_g Probability_g *
%             ( ObjectiveWeights.Sunk   * P(Sunk)   +
%               ObjectiveWeights.Taiha  * P(Taiha)  +
%               ObjectiveWeights.Chuuha * P(Chuuha) +
%               ObjectiveWeights.Chip * P(Chip) )
% 
%   目的関数 = Σ_{各艦} Σ_{各敵} (各敵艦の重み / 敵艦総数) *
%           Σ_{各交戦形態} (交戦形態を引く確率) *
%             ( 轟沈の重みパラメータ     * 轟沈率   +
%               大破の重みパラメータ     * 大破率  +
%               中破の重みパラメータ     * 中破率 +
%               カスダメの重みパラメータ * カスダメ率 )
%
% The engagement probabilities and attack-power multipliers are fixed in
% this implementation as:
%   Green T : 0.15, 1.20
%   Parallel: 0.45, 1.00
%   Head-on : 0.30, 0.80
%   Red T   : 0.10, 0.60
%
% EnemyData must contain HP, Armor, Evasion, and Luck vectors.
% EnemyWeights must contain Weight, one value per enemy.
% ObjectiveWeights must contain Sunk, Taiha, Chuuha, and Chip.
%
% support_damage_distribution is used as the source of the exact damage-state
% probabilities. The engagement multiplier is applied to the support ship's
% post-cap attack power before calling support_damage_distribution.
%
% NOTE: this implementation passes the critical-rate field returned by
% support_hitrate directly to support_damage_distribution, matching the
% supplied function interface.

%% Options
p = inputParser;
addParameter(p, 'NumStarts', 10);
addParameter(p, 'MaxIterations', 10000);
addParameter(p, 'InitialTemperature', 1);
addParameter(p, 'CoolingRate', 0.90);
addParameter(p, 'FinalTemperature', 5e-4);
addParameter(p, 'SwapProbability', 0.25);
addParameter(p, 'RandomSeed', 'shuffle');
addParameter(p, 'Verbose', true);
addParameter(p, 'RandomCandidateTrials', 6);
addParameter(p, 'HillClimbIterations', 2000);
addParameter(p, 'HillClimbCandidateTrials', 6);
addParameter(p, 'InitialJitterProbability', 0.15);
addParameter(p, 'SingleShipIterations', 100);
addParameter(p, 'SingleShipCandidateTrials', 8);
addParameter(p, 'UseParfor', false);
addParameter(p, 'EnableDominanceReduction', true);
addParameter(p, 'EnableForcedReduction', true);
addParameter(p, 'EnableEquivalentSlotReduction', true);
addParameter(p, 'DBFile', '');
addParameter(p, 'CompatibilityFile', '');
parse(p, varargin{:});
opts = p.Results;

if opts.Verbose
    fprintf('\n============================================================\n');
    fprintf('Support-fleet simulated annealing optimizer v4\n');
    fprintf('============================================================\n');
end

thisDir = fileparts(mfilename('fullpath'));
if isempty(opts.DBFile)
    opts.DBFile = firstExistingFile(thisDir, {
        'kc_firepower_database_v2.xlsx', ...
        'kc_firepower_database.xlsx', ...
        fullfile('kc_optimizer_db','kc_firepower_database.xlsx')});
end
if isempty(opts.CompatibilityFile)
    opts.CompatibilityFile = firstExistingFile(thisDir, {
        'kc_ship_slot_equipment_type_lookup_v2.xlsx', ...
        'kc_ship_slot_equipment_type_lookup_with_expansion.xlsx', ...
        'kc_ship_slot_equipment_type_lookup.xlsx'});
end

if ~isfile(opts.DBFile)
    error('Database file not found: %s', opts.DBFile);
end
if ~isfile(opts.CompatibilityFile)
    error('Compatibility file not found: %s', opts.CompatibilityFile);
end

%% Validate options
if opts.NumStarts < 1 || opts.NumStarts ~= floor(opts.NumStarts)
    error('NumStarts must be a positive integer.');
end
if opts.MaxIterations < 1 || opts.MaxIterations ~= floor(opts.MaxIterations)
    error('MaxIterations must be a positive integer.');
end
if opts.InitialTemperature <= 0
    error('InitialTemperature must be positive.');
end
if opts.FinalTemperature <= 0 || opts.FinalTemperature > opts.InitialTemperature
    error('FinalTemperature must be in (0, InitialTemperature].');
end
if opts.CoolingRate <= 0 || opts.CoolingRate >= 1
    error('CoolingRate must be between 0 and 1.');
end
if opts.SwapProbability < 0 || opts.SwapProbability > 1
    error('SwapProbability must be in [0,1].');
end

%% Validate objective inputs
validateEnemyInputs(EnemyData,EnemyWeights,ObjectiveWeights);

%% RNG / independent seeds
if ischar(opts.RandomSeed) || isstring(opts.RandomSeed)
    if strcmpi(string(opts.RandomSeed), 'shuffle')
        baseSeed = randi(2^31-2);
    else
        baseSeed = str2double(opts.RandomSeed);
        if ~isfinite(baseSeed)
            error('RandomSeed must be numeric or ''shuffle''.');
        end
    end
else
    baseSeed = double(opts.RandomSeed);
end
baseSeed = mod(floor(abs(baseSeed)), 2^31-2) + 1;
runSeeds = mod(baseSeed + (0:opts.NumStarts-1)' * 104729, 2^31-2) + 1;

%% Validate ships
shipIDs = shipIDs(:);
if numel(shipIDs) ~= 6
    error('shipIDs must contain exactly 6 ships.');
end

%% Validate expansion-slot availability
ExSlotAvailable = ExSlotAvailable(:);
if numel(ExSlotAvailable) ~= 6
    error('ExSlotAvailable must contain exactly 6 values, one per ship.');
end
if ~(islogical(ExSlotAvailable) || isnumeric(ExSlotAvailable))
    error('ExSlotAvailable must be logical or numeric.');
end
if isnumeric(ExSlotAvailable)
    if any(~isfinite(ExSlotAvailable)) || any(~ismember(ExSlotAvailable,[0 1]))
        error('Numeric ExSlotAvailable values must be 0 or 1.');
    end
    ExSlotAvailable = logical(ExSlotAvailable);
end

%% Load databases once
ships = readtable(opts.DBFile, 'Sheet', 'Ships', 'TextType', 'string');
items = readtable(opts.DBFile, 'Sheet', 'Equipment', 'TextType', 'string');
rules = readtable(opts.DBFile, 'Sheet', 'FP_BonusRules', 'TextType', 'string');
compat = readtable(opts.CompatibilityFile, ...
    'Sheet', 'SlotCompatibility', 'TextType', 'string');
expCompat = readtable(opts.CompatibilityFile, ...
    'Sheet', 'ExpansionItemLookup', 'TextType', 'string');

%% Preserve requested ship order
shipRows = zeros(6,1);
for s = 1:6
    k = find(ships.ShipID == shipIDs(s), 1);
    if isempty(k)
        error('Ship ID %d was not found.', shipIDs(s));
    end
    shipRows(s) = k;
end
selectedShips = ships(shipRows,:);

%% Searchable equipment types
FBB_TYPES = [3 38 12 13 93];
CV_TYPES  = [7 12 13 93];
DD_TYPES  = [1 12 13];

% Expansion-slot equipment categories for this optimizer.
%   12 = 小型電探, 13 = 大型電探, 93 = 大型電探（II）
%   18 = 対空強化弾 (三式弾 / 三式弾改 / 三式弾改二)
%   35 = 航空要員
%   39 = 水上艦要員
%    1 = 小口径主砲
FBB_EX_TYPES = [12 13 18 39 93];
CV_EX_TYPES  = [12 13 35 93];
DD_EX_TYPES  = [1 12 13 39];

allowedTypes = cell(6,1);
for s = 1:6
    switch selectedShips.SType(s)
        case {8,9,10}
            allowedTypes{s} = FBB_TYPES;
        case {7,11}
            allowedTypes{s} = CV_TYPES;
        case 2
            allowedTypes{s} = DD_TYPES;
        otherwise
            error(['Ship %d (%s) has unsupported SType %d. ' ...
                'Only SType 2, 7, 8, 9, 10, 11 are allowed.'], ...
                selectedShips.ShipID(s), selectedShips.Name(s), ...
                selectedShips.SType(s));
    end
end

%% Expand inventory into physical instances
requiredFields = {'ItemID','Level','Count'};
for k = 1:numel(requiredFields)
    if ~ismember(requiredFields{k}, EquipmentInventory.Properties.VariableNames)
        error('EquipmentInventory must contain column "%s".', ...
            requiredFields{k});
    end
end

countValues = double(EquipmentInventory.Count);
itemIDValues = double(EquipmentInventory.ItemID);
levelValues = double(EquipmentInventory.Level);
if any(~isfinite(countValues)) || any(countValues < 0) || any(countValues ~= floor(countValues))
    error('EquipmentInventory.Count must contain finite nonnegative integers.');
end
if any(~isfinite(itemIDValues)) || any(itemIDValues <= 0)
    error('EquipmentInventory.ItemID must contain positive finite numeric IDs.');
end
if any(~isfinite(levelValues)) || any(levelValues < 0)
    error('EquipmentInventory.Level must contain finite nonnegative numeric levels.');
end
nInv = sum(countValues);
if nInv <= 0
    error('EquipmentInventory contains no usable equipment.');
end

inventory = table();
inventory.InstanceID = (1:nInv).';
inventory.ItemID = zeros(nInv,1);
inventory.Level = zeros(nInv,1);

q = 0;
for r = 1:height(EquipmentInventory)
    n = max(0, round(EquipmentInventory.Count(r)));
    for j = 1:n
        q = q + 1;
        inventory.ItemID(q) = EquipmentInventory.ItemID(r);
        inventory.Level(q) = min(10, EquipmentInventory.Level(r));
    end
end

inventory.ItemName = strings(nInv,1);
inventory.EquipmentTypeID = zeros(nInv,1);
inventory.FirePower = zeros(nInv,1);
inventory.Torpedo = zeros(nInv,1);
inventory.Bomber = zeros(nInv,1);
inventory.Accuracy = zeros(nInv,1);

itemDBRow = containers.Map('KeyType','double','ValueType','double');
for k = 1:height(items)
    itemDBRow(double(items.ItemID(k))) = k;
end

for i = 1:nInv
    id = double(inventory.ItemID(i));
    if ~isKey(itemDBRow, id)
        error('Equipment ID %d does not exist in Equipment database.', id);
    end
    k = itemDBRow(id);
    inventory.ItemName(i) = items.Name(k);
    inventory.EquipmentTypeID(i) = items.APITypeID(k);
    inventory.FirePower(i) = items.FirePower(k);
    inventory.Torpedo(i) = items.Torpedo(k);
    inventory.Bomber(i) = items.Bomber(k);
    inventory.Accuracy(i) = items.Accuracy(k);
end

inventory.StatScore = inventory.FirePower + inventory.Torpedo + ...
    inventory.Bomber + inventory.Accuracy;

%% Build initial slot representation
%
% slotNumber == 0 denotes the expansion slot. The additional
% IsExpansionSlot metadata is kept separately so the optimizer never
% confuses it with a normal equipment slot.
slotShip = zeros(0,1);
slotNumber = zeros(0,1);
isExpansionSlot = false(0,1);
candidateInstances = {};

for s = 1:6

    %% Normal equipment slots
    rows = compat(compat.ShipID == selectedShips.ShipID(s), :);
    if isempty(rows)
        error('No slot compatibility data for ship ID %d.', ...
            selectedShips.ShipID(s));
    end
    rows = sortrows(rows, 'Slot');

    for k = 1:height(rows)
        % CV(L/B) support-shelling requires an attacking aircraft in the
        % first normal slot. This intentionally overrides the workbook's
        % ordinary slot compatibility for Slot 1: only 艦上爆撃機 (type 7)
        % or 艦上攻撃機 (type 8) may be assigned there; radars are excluded.
        if ismember(selectedShips.SType(s), [7 11]) && rows.Slot(k) == 1
            allowed = [7 8];
        else
            allowed = parseTypeIDs(rows.AllowedEquipTypeIDs(k));
            allowed = intersect(allowed, allowedTypes{s});
        end
        candidates = find(ismember(inventory.EquipmentTypeID, allowed));
        if isempty(candidates)
            error('No inventory equipment can be placed in %s slot %d.', ...
                selectedShips.Name(s), rows.Slot(k));
        end

        slotShip(end+1,1) = s; %#ok<AGROW>
        slotNumber(end+1,1) = rows.Slot(k); %#ok<AGROW>
        isExpansionSlot(end+1,1) = false; %#ok<AGROW>
        candidateInstances{end+1,1} = candidates(:); %#ok<AGROW>
    end

    %% Expansion slot
    if ExSlotAvailable(s)

        switch selectedShips.SType(s)
            case {8,9,10}
                allowedExpansionTypes = FBB_EX_TYPES;
            case {7,11}
                allowedExpansionTypes = CV_EX_TYPES;
            case 2
                allowedExpansionTypes = DD_EX_TYPES;
            otherwise
                error('Unsupported SType %d for expansion slot.', ...
                    selectedShips.SType(s));
        end

        % ExpansionItemLookup is the authoritative ship-specific feasibility
        % table. Intersect its item IDs with the requested equipment classes.
        expRows = expCompat(expCompat.ShipID == selectedShips.ShipID(s), :);
        if isempty(expRows)
            error(['Expansion slot is enabled for %s (ShipID %d), but no ' ...
                'ExpansionItemLookup entries exist.'], ...
                selectedShips.Name(s), selectedShips.ShipID(s));
        end

        requiredExpFields = {'EquipmentID','EquipmentTypeID'};
        for ff = 1:numel(requiredExpFields)
            if ~ismember(requiredExpFields{ff}, expRows.Properties.VariableNames)
                error(['ExpansionItemLookup is missing required column "%s".'], ...
                    requiredExpFields{ff});
            end
        end

        feasibleExpansionItems = unique(double(expRows.EquipmentID( ...
            ismember(double(expRows.EquipmentTypeID), allowedExpansionTypes))));

        candidates = find(ismember(double(inventory.ItemID), ...
            feasibleExpansionItems));

        if isempty(candidates)
            error(['Expansion slot is enabled for %s (ShipID %d), but the ' ...
                'inventory contains no feasible expansion-slot equipment ' ...
                'from the requested categories.'], ...
                selectedShips.Name(s), selectedShips.ShipID(s));
        end

        slotShip(end+1,1) = s; %#ok<AGROW>
        slotNumber(end+1,1) = 0; %#ok<AGROW>
        isExpansionSlot(end+1,1) = true; %#ok<AGROW>
        candidateInstances{end+1,1} = candidates(:); %#ok<AGROW>
    end
end

Nraw = numel(candidateInstances);
if nInv < Nraw
    error(['The inventory contains %d physical equipment instances, ' ...
        'but %d equipment slots must be filled.'], nInv, Nraw);
end

%% Candidate mask
candidateMask = false(Nraw,nInv);
for k = 1:Nraw
    candidateMask(k,candidateInstances{k}) = true;
end

%% High-impact preprocessing
if opts.Verbose
    fprintf('\nPreprocessing search space...\n');
    fprintf('  Raw slots: %d | Physical inventory: %d\n',Nraw,nInv);
end
preStats = struct('rawSlots',Nraw,'rawInventory',nInv, ...
    'dominatedItemIDs',0,'forcedSlots',0,'equivalentGroups',0);

if opts.EnableDominanceReduction
    protectedItemIDs = collectProtectedItemIDs(rules);
    [candidateMask, dominatedCount] = eliminateDominatedEquipment( ...
        candidateMask, inventory, slotShip, protectedItemIDs);
    preStats.dominatedItemIDs = dominatedCount;
end

% Remove candidates made unavailable by dominance.
candidateInstances = maskToCandidateCells(candidateMask);
for k = 1:numel(candidateInstances)
    if isempty(candidateInstances{k})
        error(['Preprocessing removed every candidate from slot %d. ' ...
            'Disable EnableDominanceReduction if this is unexpected.'], k);
    end
end

% Preserve the post-dominance full-slot mask for validation.
fullCandidateMask = candidateMask;

% Resolve forced assignments. The routine is deliberately conservative:
% singleton slots and saturated connected components only.
forcedStateOriginal = zeros(Nraw,1);
if opts.EnableForcedReduction
    [candidateMask, forcedStateOriginal, forcedCount] = resolveForcedAssignments( ...
        candidateMask, slotShip, nInv);
    preStats.forcedSlots = forcedCount;
end

%% Search-space representation
originalSlotShip = slotShip;
originalSlotNumber = slotNumber;
originalIsExpansionSlot = isExpansionSlot;
remainingSlots = find(forcedStateOriginal == 0);
if isempty(remainingSlots)
    fprintf('  All slots were resolved by preprocessing. Skipping SA.\n');
    searchCandidateMask=false(0,nInv); searchCandidateInstances=cell(0,1);
    searchSlotShip=zeros(0,1); N=0;
else
    searchCandidateMask=candidateMask(remainingSlots,:);
    searchCandidateInstances=maskToCandidateCells(searchCandidateMask);
    searchSlotShip=originalSlotShip(remainingSlots);
    N=numel(remainingSlots);
end
shipSlots=cell(6,1);
for s=1:6, shipSlots{s}=find(originalSlotShip==s); end
searchShipSlots=cell(6,1);
for s=1:6, searchShipSlots{s}=find(searchSlotShip==s); end

%% Equivalent-slot groups
equivGroups={}; equivRep=(1:N).';
if opts.EnableEquivalentSlotReduction && N>0
    [groupsSearch,equivRep]=buildEquivalentGroups(searchCandidateMask,searchSlotShip);
    equivGroups=cell(size(groupsSearch));
    for g=1:numel(groupsSearch), equivGroups{g}=remainingSlots(groupsSearch{g}); end
    preStats.equivalentGroups=numel(equivGroups);
end
canonicalOrder=buildCanonicalOrder(equivGroups,inventory);

%% Precompute legal search-space swaps
swapOK=false(N,N);
for a=1:max(0,N-1)
    ca=searchCandidateMask(a,:);
    for b=a+1:N
        if equivRep(a)==equivRep(b),continue;end
        if any(ca & searchCandidateMask(b,:))
            swapOK(a,b)=true; swapOK(b,a)=true;
        end
    end
end
swapNeighbors=cell(N,1);
for a=1:N, swapNeighbors{a}=find(swapOK(a,:)); end

%% Strong initial full state
initialState=zeros(Nraw,1); forcedMask=forcedStateOriginal~=0;
if any(forcedMask), initialState(forcedMask)=forcedStateOriginal(forcedMask); end
usedInitial=false(nInv,1);
if any(forcedMask), usedInitial(initialState(forcedMask))=true; end
if N>0
    reducedInitialState=makeBestStatFeasibleStateWithUsed(searchCandidateInstances,inventory.StatScore,usedInitial);
    initialState(remainingSlots)=reducedInitialState;
end
if ~stateIsFeasibleFull(initialState,fullCandidateMask,nInv)
    error('Internal error: preprocessing produced an infeasible initial state.');
end
initialState=canonicalizeState(initialState,equivGroups,inventory);
fprintf('  Initial state constructed: %d forced + %d searchable slots.\n',nnz(forcedMask),N);
fprintf('  Expansion slots enabled: %d / 6.\n',nnz(ExSlotAvailable));
if opts.Verbose
    fprintf('  Dominance reduction: %d item IDs removed.\n',preStats.dominatedItemIDs);
    fprintf('  Forced reduction: %d slots resolved.\n',preStats.forcedSlots);
    fprintf('  Equivalent-slot groups: %d.\n',preStats.equivalentGroups);
end

%% Independent SA starts
if N == 0
    allRuns = struct('Objective',[],'State',[],'History',[],'Iterations',0, ...
        'Seed',runSeeds(1),'ElapsedTime',0);
    objective0 = 0;
    for s = 1:6
        objective0 = objective0 + evaluateShipObjective(initialState,s,shipSlots, ...
            selectedShips,inventory,ships,items,rules,HitrateOptions, ...
            EnemyData,EnemyWeights,ObjectiveWeights);
    end
    allRuns.Objective = objective0;
    allRuns.State = initialState;
    allRuns.History = zeros(0,2);
    bestRun = 1;
    fprintf('  Fully resolved objective: %.9f\n',objective0);
else
    allRuns = repmat(struct('Objective',[],'State',[],'History',[], ...
        'Iterations',0,'Seed',[],'ElapsedTime',[]),opts.NumStarts,1);

    fprintf('\n============================================================\n');
    fprintf('Starting simulated annealing: %d independent run(s)\n',opts.NumStarts);
    fprintf('Search slots: %d / %d\n',N,Nraw);
    fprintf('Iterations per run: %d\n',opts.MaxIterations);
    fprintf('============================================================\n');
    
    if opts.UseParfor
    
        parfor run = 1:opts.NumStarts
    
            allRuns(run) = runSingleSA( ...
                run, ...
                runSeeds(run), ...
                opts, ...
                initialState, ...
                remainingSlots, ...
                searchCandidateInstances, ...
                searchCandidateMask, ...
                swapNeighbors, ...
                searchSlotShip, ...
                originalSlotShip, ...
                shipSlots, ...
                searchShipSlots, ...
                equivGroups, ...
                canonicalOrder, ...
                selectedShips, ...
                inventory, ...
                ships, ...
                items, ...
                rules, ...
                HitrateOptions, ...
                EnemyData, ...
                EnemyWeights, ...
                ObjectiveWeights);
    
        end
    
    else
    
        for run = 1:opts.NumStarts
    
            allRuns(run) = runSingleSA( ...
                run, ...
                runSeeds(run), ...
                opts, ...
                initialState, ...
                remainingSlots, ...
                searchCandidateInstances, ...
                searchCandidateMask, ...
                swapNeighbors, ...
                searchSlotShip, ...
                originalSlotShip, ...
                shipSlots, ...
                searchShipSlots, ...
                equivGroups, ...
                canonicalOrder, ...
                selectedShips, ...
                inventory, ...
                ships, ...
                items, ...
                rules, ...
                HitrateOptions, ...
                EnemyData, ...
                EnemyWeights, ...
                ObjectiveWeights);
    
        end
    
    end
end

%% Select global best
objectives=[allRuns.Objective]; [bestObjective,bestRun]=max(objectives);
bestState=allRuns(bestRun).State; bestHistory=allRuns(bestRun).History;
fullState=bestState;
if opts.Verbose && N > 0
    fprintf('\nBest SA run: %d/%d | Objective = %.9f | elapsed = %.3f s\n', ...
        bestRun,opts.NumStarts,bestObjective,allRuns(bestRun).ElapsedTime);
end

%% Decode best solution
bestAssignment = table();
for k = 1:Nraw
    i = fullState(k);
    s = originalSlotShip(k);
    slotNo = originalSlotNumber(k);
    ex = originalIsExpansionSlot(k);

    row = table( ...
        s, selectedShips.ShipID(s), selectedShips.Name(s), slotNo, ex, ...
        inventory.ItemID(i), inventory.ItemName(i), inventory.Level(i), ...
        inventory.EquipmentTypeID(i), ...
        'VariableNames', {'ShipIndex','ShipID','ShipName','Slot', ...
        'IsExpansionSlot','ItemID','ItemName','Level','EquipmentTypeID'});
    bestAssignment = [bestAssignment; row]; %#ok<AGROW>
end

% Cosmetic output ordering only: do not alter fullState or any objective
% calculation. For FBB/VBB/DD ships, guns are displayed before radars;
% for CVL/B ships, aircraft are displayed before radars. The actual Slot
% and IsExpansionSlot values remain unchanged.
bestAssignment = orderBestAssignmentForDisplay(bestAssignment, selectedShips);

%% Detailed final results
% Use the exact internal slot map so expansion slots are included.
finalShipSlots = cell(6,1);
finalSlotNumbers = originalSlotNumber;
finalSlotShips = originalSlotShip;
finalIsExpansionSlot = originalIsExpansionSlot;

for k = 1:Nraw
    s = finalSlotShips(k);
    finalShipSlots{s}(end+1) = k; %#ok<AGROW>
end

shipResults = cell(6,1);
shipObjective = zeros(6,1);

for s = 1:6
    slots = finalShipSlots{s};
    assigned = fullState(slots);
    itemIDs = inventory.ItemID(assigned);
    levels = inventory.Level(assigned);

    [supportFP, detail] = support_firepower_fast( ...
        selectedShips.ShipID(s), itemIDs, levels, ships, items, rules);

    h = getHitrateOptions(HitrateOptions,s);
    attackerAcc = sum(inventory.Accuracy(assigned));
    if isfield(h,'attackerAcc')
        attackerAcc = attackerAcc + h.attackerAcc;
    end

    expected = evaluateShipExpectedObjective( ...
        selectedShips.ShipID(s), detail, attackerAcc, h, ...
        EnemyData, EnemyWeights, ObjectiveWeights);

    shipObjective(s) = expected.totalObjective;
    shipResults{s} = expected;
    shipResults{s}.ShipID = selectedShips.ShipID(s);
    shipResults{s}.ShipName = selectedShips.Name(s);
    shipResults{s}.ItemIDs = itemIDs;
    shipResults{s}.Levels = levels;
    shipResults{s}.SupportFP = supportFP;
    shipResults{s}.Detail = detail;
    shipResults{s}.HitrateByEnemy = expected.HitrateByEnemy;
end

% The final detailed evaluation is the authoritative value of the objective.
bestObjective = sum(shipObjective);

%% Output
result = struct();
result.bestObjective = bestObjective;
result.bestAssignment = bestAssignment;
result.bestShips = selectedShips;
result.shipResults = shipResults;
result.shipObjective = shipObjective;
result.history = bestHistory;
result.allRuns = allRuns;
result.preprocessing = preStats;
result.preprocessing.remainingSlots = N;
result.preprocessing.rawSlots = Nraw;
result.preprocessing.remainingInventory = nInv - numel(unique(fullState));
result.preprocessing.forcedAssignment = forcedStateOriginal;
result.options = opts;
result.EnemyData = EnemyData;
result.EnemyWeights = EnemyWeights;
result.ObjectiveWeights = ObjectiveWeights;
result.ExSlotAvailable = ExSlotAvailable;
result.slotMetadata = table( ...
    originalSlotShip, originalSlotNumber, originalIsExpansionSlot, ...
    'VariableNames', {'ShipIndex','Slot','IsExpansionSlot'});
result.EngagementOptions = struct( ...
    'Probability',[0.15 0.45 0.30 0.10], ...
    'AttackMultiplier',[1.20 1.00 0.80 0.60], ...
    'Names',{{'CrossingT_Green','Parallel','HeadOn','CrossingT_Red'}});

fprintf('\n============================================\n');
fprintf('Best expected objective: %.9f\n', result.bestObjective);
fprintf('Expected objective by ship:\n');
for s = 1:6
    fprintf('  %d: %-20s %.9f\n', s, string(selectedShips.Name(s)), shipObjective(s));
end
fprintf('Preprocessing: %d -> %d searchable slots; %d dominated item IDs; %d forced slots; %d equivalent groups\n', ...
    Nraw, N, preStats.dominatedItemIDs, preStats.forcedSlots, preStats.equivalentGroups);
fprintf('PARFOR: %s\n', ternary(opts.UseParfor,'ON','OFF'));
fprintf('============================================\n');
disp(result.bestAssignment);

end


%% ========================================================================
function out = runSingleSA(run,seed,opts,initialState,remainingSlots,candidateInstances, ...
    candidateMask,swapNeighbors,searchSlotShip,originalSlotShip, ...
    shipSlots,searchShipSlots,equivGroups,canonicalOrder,selectedShips,inventory,ships,items,rules, ...
    HitrateOptions,EnemyData,EnemyWeights,ObjectiveWeights)
runTimer=tic; rng(seed,'twister'); N=numel(remainingSlots); nInv=height(inventory);
fprintf('\n------------------------------------------------------------\n');
fprintf('SA run %d/%d | Seed = %d\n',run,opts.NumStarts,seed);
fprintf('  [1/4] Preparing initial state...\n');
state=initialState;
if opts.InitialJitterProbability>0 && N>0
    state=jitterFullState(state,remainingSlots,candidateInstances,opts.InitialJitterProbability,nInv,candidateMask);
    state=canonicalizeState(state,equivGroups,inventory);
end
fprintf('        Initial jitter probability: %.1f%%\n',100*opts.InitialJitterProbability);
fprintf('  [2/4] Single-ship coordinate improvement...\n');
[state,localInitObjective]=singleShipCoordinateImprove(state,remainingSlots,searchSlotShip,searchShipSlots, ...
    shipSlots,candidateInstances,candidateMask,selectedShips,inventory,ships,items,rules,HitrateOptions, ...
    EnemyData,EnemyWeights,ObjectiveWeights,opts.SingleShipIterations,opts.SingleShipCandidateTrials,equivGroups);
state=canonicalizeState(state,equivGroups,inventory);
fprintf('  [3/4] Evaluating starting objective...\n');
shipObjective=zeros(6,1);
for s=1:6
    shipObjective(s)=evaluateShipObjective(state,s,shipSlots,selectedShips,inventory,ships,items,rules,HitrateOptions,EnemyData,EnemyWeights,ObjectiveWeights);
end
currentObjective=sum(shipObjective);
if abs(currentObjective-localInitObjective)>1e-10, fprintf('        Objective after canonicalization: %.9f\n',currentObjective); end
localBestObjective=currentObjective; localBestState=state;
fprintf('        Starting objective: %.9f\n',currentObjective);

history=zeros(opts.MaxIterations,2); T0=opts.InitialTemperature; Tf=opts.FinalTemperature; alpha=opts.CoolingRate; T=T0;
used=false(nInv,1); used(state)=true;
fprintf('  [4/4] Simulated annealing...\n');
progressStep=max(1,floor(opts.MaxIterations/100));
nTemp=max(1,ceil(log(Tf/T0)/log(alpha))); phaseLength=max(1,ceil(opts.MaxIterations/max(1,nTemp))); lastIter=0;

for iter=1:opts.MaxIterations
    lastIter=iter;
    if iter>1 && mod(iter-1,phaseLength)==0, T=max(Tf,T*alpha); end
    newState=state; moveType=0; affectedFullSlots=zeros(0,1);
    if rand<opts.SwapProbability && N>=2
        [a,b,ok]=chooseSwap(state,swapNeighbors,candidateMask,opts.RandomCandidateTrials);
        if ok
            fullA=remainingSlots(a); fullB=remainingSlots(b); newState([fullA fullB])=state([fullB fullA]);
            affectedFullSlots=[fullA;fullB]; moveType=1;
        end
    else
        [a,newItem,ok]=chooseReplacement(state,used,remainingSlots,candidateInstances,candidateMask,opts.RandomCandidateTrials);
        if ok
            fullA=remainingSlots(a); newState(fullA)=newItem; affectedFullSlots=fullA; moveType=2;
        end
    end
    if moveType==0
        history(iter,:)=[currentObjective T];
        if opts.Verbose && ~opts.UseParfor && mod(iter,progressStep)==0
            fprintf('Run %d/%d | Iteration %d/%d | no legal move | Current = %.6f | Best = %.6f | T = %.6g\n',run,opts.NumStarts,iter,opts.MaxIterations,currentObjective,localBestObjective,T);
        end
        continue;
    end
    affectedShipsBefore=unique(originalSlotShip(affectedFullSlots));
    newState=canonicalizeAffectedState(newState,affectedShipsBefore,shipSlots,equivGroups,inventory,canonicalOrder);
    changedFullSlots=find(state~=newState); affectedShips=unique(originalSlotShip(changedFullSlots));
    if isempty(affectedShips), history(iter,:)=[currentObjective T]; continue; end
    newShipObjective=shipObjective; newObjective=currentObjective;
    for jj=1:numel(affectedShips)
        s=affectedShips(jj);
        newValue=evaluateShipObjective(newState,s,shipSlots,selectedShips,inventory,ships,items,rules,HitrateOptions,EnemyData,EnemyWeights,ObjectiveWeights);
        newObjective=newObjective-shipObjective(s)+newValue; newShipObjective(s)=newValue;
    end
    delta=newObjective-currentObjective;
    if delta>=0, accept=true; else, accept=rand<exp(max(-745,delta/max(T,realmin))); end
    if accept
        state=newState; currentObjective=newObjective; shipObjective=newShipObjective; used=false(nInv,1); used(state)=true;
        if currentObjective>localBestObjective, localBestObjective=currentObjective; localBestState=state; end
    end
    history(iter,:)=[currentObjective T];
    if opts.Verbose && ~opts.UseParfor && mod(iter,progressStep)==0
        fprintf('Run %d/%d | Iteration %d/%d | Current = %.6f | Best = %.6f | T = %.6g\n',run,opts.NumStarts,iter,opts.MaxIterations,currentObjective,localBestObjective,T);
    end
end
history=history(1:lastIter,:);
fprintf('  Final local hill climb...\n');
[localBestState,localBestObjective]=hillClimbState(localBestState,localBestObjective,remainingSlots,candidateInstances,candidateMask,swapNeighbors,searchSlotShip,originalSlotShip,shipSlots,selectedShips,inventory,ships,items,rules,HitrateOptions,EnemyData,EnemyWeights,ObjectiveWeights,opts.HillClimbIterations,opts.HillClimbCandidateTrials,equivGroups,canonicalOrder);
out.Objective=localBestObjective; out.State=localBestState; out.History=history; out.Iterations=lastIter; out.Seed=seed; out.ElapsedTime=toc(runTimer);
fprintf('SA run %d/%d finished: best objective = %.9f | elapsed = %.3f s\n',run,opts.NumStarts,localBestObjective,out.ElapsedTime);
fprintf('------------------------------------------------------------\n');
end

function [candidateMask,removedCount] = eliminateDominatedEquipment(candidateMask,inventory,slotShip,protectedItemIDs)
% Conservative dominance reduction. An item ID is removed only when every
% physical copy is matched by a distinct copy of another item of the same
% API type whose base stats are no worse AND whose level is no lower. Item
% IDs referenced by bonus rules are protected.
removedCount=0;
itemIDs=unique(inventory.ItemID);
changed=true;
while changed
    changed=false;
    for ii=1:numel(itemIDs)
        idB=itemIDs(ii);
        if any(protectedItemIDs==idB),continue;end
        idxB=find(inventory.ItemID==idB);
        if isempty(idxB),continue;end
        slotsB=find(any(candidateMask(:,idxB),2));
        if isempty(slotsB),continue;end
        typeB=inventory.EquipmentTypeID(idxB(1));

        % Every B instance must have a distinct A instance that is at least
        % as strong at the same or higher enhancement level.
        availableA=false(numel(idxB),1);
        for bb=1:numel(idxB)
            b=idxB(bb);
            eligible=find(inventory.EquipmentTypeID==typeB & inventory.ItemID~=idB & inventory.InstanceID~=inventory.InstanceID(b));
            eligible=eligible(inventory.Level(eligible)>=inventory.Level(b));
            dominates=(inventory.FirePower(eligible)>=inventory.FirePower(b)) & ...
                (inventory.Torpedo(eligible)>=inventory.Torpedo(b)) & ...
                (inventory.Bomber(eligible)>=inventory.Bomber(b)) & ...
                (inventory.Accuracy(eligible)>=inventory.Accuracy(b));
            dominates=eligible(dominates);
            if isempty(dominates)
                availableA(bb)=false;
            else
                availableA(bb)=true;
            end
        end
        if ~all(availableA),continue;end

        % There must also be enough such dominant copies to replace the
        % B copies without consuming an instance needed by another slot.
        dominantPool=false(height(inventory),1);
        for bb=1:numel(idxB)
            b=idxB(bb);
            eligible=find(inventory.EquipmentTypeID==typeB & inventory.ItemID~=idB & inventory.InstanceID~=inventory.InstanceID(b));
            eligible=eligible(inventory.Level(eligible)>=inventory.Level(b));
            dominates=(inventory.FirePower(eligible)>=inventory.FirePower(b)) & ...
                (inventory.Torpedo(eligible)>=inventory.Torpedo(b)) & ...
                (inventory.Bomber(eligible)>=inventory.Bomber(b)) & ...
                (inventory.Accuracy(eligible)>=inventory.Accuracy(b));
            dominantPool(eligible(dominates))=true;
        end
        if nnz(dominantPool)>=numel(idxB)
            candidateMask(:,idxB)=false;
            removedCount=removedCount+1;
            changed=true;
        end
    end
end
unused=slotShip; %#ok<NASGU>
end

%% ========================================================================
function protectedIDs = collectProtectedItemIDs(rules)
% Any item explicitly referenced by an FP bonus rule is protected from the
% raw-stat dominance reduction. This is intentionally conservative.
protectedIDs = [];
fields = {'TriggerItemIDs','RequiresItemIDs','RequiresItemIDs2'};
for f = 1:numel(fields)
    if ~ismember(fields{f},rules.Properties.VariableNames)
        continue;
    end
    for r = 1:height(rules)
        x = rules.(fields{f})(r);
        ids = parseTypeIDs(x);
        protectedIDs = [protectedIDs; ids(:)]; %#ok<AGROW>
    end
end
protectedIDs = unique(protectedIDs(~isnan(protectedIDs)));
end

%% ========================================================================
function [mask, forcedState, forcedCount] = resolveForcedAssignments(mask,...
    slotShip,nInv)
% Conservative forced-slot reduction.
% 1) Repeatedly resolve singleton slots.
% 2) For each connected component of the slot<->inventory bipartite graph,
%    if the component has exactly as many physical candidates as slots,
%    all those physical instances are forced to remain inside that
%    component; they are removed from every other component.
%
% The second operation reduces cross-component coupling without choosing an
% arbitrary permutation inside a component.

N = size(mask,1);
forcedState = zeros(N,1);
used = false(nInv,1);
changed = true;

while changed
    changed = false;

    % Singleton propagation.
    for k = 1:N
        if forcedState(k) ~= 0
            continue;
        end
        c = find(mask(k,:) & ~used);
        if numel(c) == 1
            forcedState(k) = c;
            used(c) = true;
            mask(:,c) = false;
            mask(k,c) = true;
            changed = true;
        end
    end

    % Saturated connected components. This is a Hall-type safe reduction.
    activeSlots = find(forcedState == 0);
    if isempty(activeSlots)
        break;
    end

    [components] = bipartiteComponents(mask(activeSlots,:), activeSlots, used);
    for cc = 1:numel(components)
        sl = components(cc).slots;
        it = components(cc).items;
        if numel(sl) == numel(it) && ~isempty(sl)
            % These items cannot be used outside this component.
            outsideSlots = setdiff(activeSlots,sl);
            if ~isempty(outsideSlots) && ~isempty(it)
                before = mask(outsideSlots,it);
                mask(outsideSlots,it) = false;
                if any(before(:))
                    changed = true;
                end
            end
        end
    end
end

% Return only non-forced candidates; forced physical instances are consumed.
for k = 1:N
    if forcedState(k) ~= 0
        mask(k,:) = false;
    end
end
forcedCount = nnz(forcedState);

% Ensure no unresolved slot was accidentally emptied.
for k = find(forcedState == 0)'
    if ~any(mask(k,:))
        error(['Forced-assignment preprocessing left slot %d with no ' ...
            'candidate.'],k);
    end
end

% slotShip is intentionally an input because a future extension can use it
% for ship-aware component reductions; retain it to keep the helper API
% explicit.
unused = slotShip; %#ok<NASGU>
end

%% ========================================================================
function components = bipartiteComponents(mask,globalSlots,used)
% Connected components in a bipartite graph of active slots and inventory
% instances. Only unused inventory nodes are considered.
N = size(mask,1);
usedItems = find(any(mask,1) & ~used(:)');
visitedS = false(N,1);
visitedI = false(1,size(mask,2));
components = struct('slots',{},'items',{});

for s0 = 1:N
    if visitedS(s0) || ~any(mask(s0,:))
        continue;
    end
    queueS = s0;
    slotsLocal = [];
    itemsLocal = [];
    while ~isempty(queueS)
        s = queueS(end); queueS(end) = [];
        if visitedS(s), continue; end
        visitedS(s) = true;
        slotsLocal(end+1) = globalSlots(s); %#ok<AGROW>
        itemsHere = find(mask(s,:) & ~used(:)');
        for i = itemsHere
            if ~visitedI(i)
                visitedI(i) = true;
                itemsLocal(end+1) = i; %#ok<AGROW>
                moreS = find(mask(:,i));
                queueS = [queueS; moreS(~visitedS(moreS))]; %#ok<AGROW>
            end
        end
    end
    components(end+1).slots = slotsLocal; %#ok<AGROW>
    components(end).items = itemsLocal;
end

% Silence an otherwise unused variable in older MATLAB versions.
unused = usedItems; %#ok<NASGU>
end

%% ========================================================================
function cells = maskToCandidateCells(mask)
cells = cell(size(mask,1),1);
for k = 1:size(mask,1)
    cells{k} = find(mask(k,:))';
end
end

%% ========================================================================
function [groups,rep] = buildEquivalentGroups(mask,slotShip)
% Conservative equivalent groups: same ship and exactly identical candidate
% instance sets. Such slots are objective-symmetric.
N = size(mask,1);
rep = (1:N).';
groups = {};
keys = containers.Map('KeyType','char','ValueType','double');
for k = 1:N
    ids = find(mask(k,:));
    key = sprintf('%d|%s',slotShip(k),sprintf('%d,',ids));
    if isKey(keys,key)
        g = keys(key);
        groups{g}(end+1) = k;
        rep(k) = groups{g}(1);
    else
        groups{end+1} = k; %#ok<AGROW>
        keys(key) = numel(groups);
    end
end
end

%% ========================================================================
function order = buildCanonicalOrder(groups,inventory)
order = (1:height(inventory))';
% This helper stores a deterministic instance ranking used only to order
% equivalent-slot contents.
[~,order] = sortrows([inventory.ItemID inventory.Level inventory.InstanceID],...
    [1 2 3]);
unused = groups; %#ok<NASGU>
end

%% ========================================================================
function state = canonicalizeState(state,groups,inventory)
for g = 1:numel(groups)
    slots = groups{g};
    if numel(slots) <= 1, continue; end
    vals = state(slots);
    key = [inventory.ItemID(vals),inventory.Level(vals),vals];
    [~,ix] = sortrows(key,[1 2 3]);
    state(slots) = vals(ix);
end
end

%% ========================================================================
function state = canonicalizeAffectedState(state,affectedShips,shipSlots,...
    groups,inventory,canonicalOrder)
for g = 1:numel(groups)
    slots = groups{g};
    if numel(slots) <= 1, continue; end
    if any(ismember(affectedShips,unique(shipSlotsContaining(slots,shipSlots))))
        vals = state(slots);
        key = [inventory.ItemID(vals),inventory.Level(vals),vals];
        [~,ix] = sortrows(key,[1 2 3]);
        state(slots) = vals(ix);
    end
end
unused = canonicalOrder; %#ok<NASGU>
end

%% ========================================================================
function shipsOut = shipSlotsContaining(slots,shipSlots)
shipsOut = [];
for s = 1:numel(shipSlots)
    if any(ismember(shipSlots{s},slots))
        shipsOut(end+1) = s; %#ok<AGROW>
    end
end
end

%% ========================================================================
function state=makeBestStatFeasibleStateWithUsed(candidateInstances,statScore,used)
N=numel(candidateInstances);state=zeros(N,1);counts=cellfun(@numel,candidateInstances);[~,order]=sort(counts,'ascend');
for ii=1:N,k=order(ii);c=candidateInstances{k};c=c(~used(c));if isempty(c),error('Could not construct a feasible initial assignment. No unused candidate remains for search slot %d.',k);end;[~,j]=max(statScore(c));state(k)=c(j);used(c(j))=true;end
end

%% ========================================================================
function ok=stateIsFeasibleFull(state,candidateMask,nInv)
if numel(state)~=size(candidateMask,1),error('Internal indexing error in stateIsFeasibleFull.');end
ok=all(state>=1 & state<=nInv) && numel(unique(state))==numel(state);if ~ok,return;end
for k=1:numel(state),if ~candidateMask(k,state(k)),ok=false;return;end,end
end

function state=jitterFullState(state,remainingSlots,candidateInstances,p,nInv,mask)
N=numel(remainingSlots); if N==0 || p<=0,return;end
used=false(nInv,1);used(state)=true;nMoves=max(1,round(p*N));
for q=1:nMoves
    a=randi(N);fullA=remainingSlots(a);list=candidateInstances{a};
    possible=list(~used(list) & list~=state(fullA));possible=possible(mask(a,possible));
    if isempty(possible),continue;end
    newItem=possible(randi(numel(possible)));oldItem=state(fullA);state(fullA)=newItem;used(oldItem)=false;used(newItem)=true;
end
end

%% ========================================================================
function [a,b,ok]=chooseSwap(state,swapNeighbors,mask,trials)
N=numel(swapNeighbors);a=0;b=0;ok=false;if N<2,return;end
for t=1:max(1,trials)
    aa=randi(N);neigh=swapNeighbors{aa};if isempty(neigh),continue;end
    bb=neigh(randi(numel(neigh)));ia=state(aa);ib=state(bb);
    if ia~=ib && mask(aa,ib) && mask(bb,ia),a=aa;b=bb;ok=true;return;end
end
order=randperm(N);
for ii=1:N
    aa=order(ii);neigh=swapNeighbors{aa};if isempty(neigh),continue;end;no=randperm(numel(neigh));
    for jj=1:numel(no)
        bb=neigh(no(jj));ia=state(aa);ib=state(bb);
        if ia~=ib && mask(aa,ib) && mask(bb,ia),a=aa;b=bb;ok=true;return;end
    end
end
end

%% ========================================================================
function [a,newItem,ok]=chooseReplacement(state,used,remainingSlots,candidateInstances,mask,trials)
N=numel(candidateInstances);a=0;newItem=0;ok=false;if N==0,return;end
for t=1:max(1,trials)
    aa=randi(N);list=candidateInstances{aa};possible=list(~used(list));possible=possible(possible~=state(remainingSlots(aa)));possible=possible(mask(aa,possible));
    if ~isempty(possible),a=aa;newItem=possible(randi(numel(possible)));ok=true;return;end
end
order=randperm(N);
for ii=1:N
    aa=order(ii);list=candidateInstances{aa};possible=list(~used(list));possible=possible(possible~=state(remainingSlots(aa)));possible=possible(mask(aa,possible));
    if ~isempty(possible),a=aa;newItem=possible(randi(numel(possible)));ok=true;return;end
end
end

%% ========================================================================
function [state,obj]=singleShipCoordinateImprove(state,remainingSlots,searchSlotShip,searchShipSlots,shipSlots,candidateInstances,mask,selectedShips,inventory,ships,items,rules,HitrateOptions,EnemyData,EnemyWeights,ObjectiveWeights,maxIterations,candidateTrials,equivGroups)
startTimer=tic;fprintf('    --- Single-ship coordinate improvement ---\n');fprintf('      Max iterations: %d | Candidate trials: %d\n',maxIterations,candidateTrials);
obj=0;for s=1:6,obj=obj+evaluateShipObjective(state,s,shipSlots,selectedShips,inventory,ships,items,rules,HitrateOptions,EnemyData,EnemyWeights,ObjectiveWeights);end
fprintf('      Initial objective: %.9f\n',obj);
if maxIterations<=0 || isempty(remainingSlots),fprintf('      Coordinate search skipped.\n');fprintf('      Elapsed time: %.3f s\n',toc(startTimer));return;end
nInv=height(inventory);used=false(nInv,1);used(state)=true;totalAccepted=0;totalEvaluations=0;fprintf('      Running coordinate search...\n');
for it=1:maxIterations
    improved=false;order=randperm(6);
    for oo=1:numel(order)
        s=order(oo);searchSlots=searchShipSlots{s};if isempty(searchSlots),continue;end
        oldVal=evaluateShipObjective(state,s,shipSlots,selectedShips,inventory,ships,items,rules,HitrateOptions,EnemyData,EnemyWeights,ObjectiveWeights);totalEvaluations=totalEvaluations+1;
        for trial=1:max(1,candidateTrials)
            a=searchSlots(randi(numel(searchSlots)));fullA=remainingSlots(a);list=candidateInstances{a};possible=list(~used(list));possible=possible(possible~=state(fullA));possible=possible(mask(a,possible));if isempty(possible),continue;end
            nt=min(numel(possible),max(1,candidateTrials));possible=possible(randperm(numel(possible),nt));bestVal=oldVal;bestItem=0;bestState=state;
            for pp=1:numel(possible)
                newState=state;newState(fullA)=possible(pp);newState=canonicalizeState(newState,equivGroups,inventory);
                newVal=evaluateShipObjective(newState,s,shipSlots,selectedShips,inventory,ships,items,rules,HitrateOptions,EnemyData,EnemyWeights,ObjectiveWeights);totalEvaluations=totalEvaluations+1;
                if newVal>bestVal,bestVal=newVal;bestItem=possible(pp);bestState=newState;end
            end
            if bestItem~=0,state=bestState;used=false(nInv,1);used(state)=true;obj=obj-oldVal+bestVal;totalAccepted=totalAccepted+1;improved=true;break;end
        end
        if improved,break;end
    end
    if improved
        if mod(it,10)==0 || it==1,fprintf('      Iteration %d/%d: improved -> %.9f\n',it,maxIterations,obj);end
    else,fprintf('      Iteration %d/%d: no improvement, converged.\n',it,maxIterations);break;end
end
fprintf('      Coordinate search finished.\n');fprintf('        Accepted improvements: %d\n',totalAccepted);fprintf('        Objective evaluations: %d\n',totalEvaluations);fprintf('        Final objective: %.9f\n',obj);fprintf('        Elapsed time: %.3f s\n',toc(startTimer));unused=searchSlotShip; %#ok<NASGU>
end

%% ========================================================================
function [bestState,bestObjective]=hillClimbState(state,objective,remainingSlots,candidateInstances,mask,swapNeighbors,searchSlotShip,originalSlotShip,shipSlots,selectedShips,inventory,ships,items,rules,HitrateOptions,EnemyData,EnemyWeights,ObjectiveWeights,maxIterations,candidateTrials,equivGroups,canonicalOrder)
bestState=state;bestObjective=objective;N=numel(remainingSlots);nInv=height(inventory);used=false(nInv,1);used(state)=true;shipObjective=zeros(6,1);
for s=1:6,shipObjective(s)=evaluateShipObjective(state,s,shipSlots,selectedShips,inventory,ships,items,rules,HitrateOptions,EnemyData,EnemyWeights,ObjectiveWeights);end
if maxIterations<=0 || N==0,return;end
for iter=1:maxIterations
    improved=false;
    for trial=1:max(1,candidateTrials)
        [a,newItem,ok]=chooseReplacement(state,used,remainingSlots,candidateInstances,mask,2);if ~ok,break;end
        fullA=remainingSlots(a);newState=state;newState(fullA)=newItem;newState=canonicalizeState(newState,equivGroups,inventory);changed=find(state~=newState);affected=unique(originalSlotShip(changed));newObjective=bestObjective;newValues=shipObjective;
        for jj=1:numel(affected),ss=affected(jj);newValues(ss)=evaluateShipObjective(newState,ss,shipSlots,selectedShips,inventory,ships,items,rules,HitrateOptions,EnemyData,EnemyWeights,ObjectiveWeights);newObjective=newObjective-shipObjective(ss)+newValues(ss);end
        if newObjective>bestObjective,state=newState;bestState=state;bestObjective=newObjective;shipObjective=newValues;used=false(nInv,1);used(state)=true;improved=true;break;end
    end
    if improved,continue;end
    for trial=1:max(1,candidateTrials)
        [a,b,ok]=chooseSwap(state,swapNeighbors,mask,2);if ~ok,break;end
        fullA=remainingSlots(a);fullB=remainingSlots(b);newState=state;newState([fullA fullB])=state([fullB fullA]);affected=unique(originalSlotShip([fullA;fullB]));newState=canonicalizeAffectedState(newState,affected,shipSlots,equivGroups,inventory,canonicalOrder);changed=find(state~=newState);affected=unique(originalSlotShip(changed));newObjective=bestObjective;newValues=shipObjective;
        for jj=1:numel(affected),ss=affected(jj);newValues(ss)=evaluateShipObjective(newState,ss,shipSlots,selectedShips,inventory,ships,items,rules,HitrateOptions,EnemyData,EnemyWeights,ObjectiveWeights);newObjective=newObjective-shipObjective(ss)+newValues(ss);end
        if newObjective>bestObjective,state=newState;bestState=state;bestObjective=newObjective;shipObjective=newValues;used=false(nInv,1);used(state)=true;improved=true;break;end
    end
    if ~improved,break;end
end
unused=searchSlotShip; %#ok<NASGU>
end

%% ========================================================================
function value=evaluateShipObjective(state,shipIndex,shipSlots,selectedShips,...
    inventory,ships,items,rules,HitrateOptions,EnemyData,EnemyWeights,ObjectiveWeights)
% Evaluate the expected weighted damage-state objective for one ship.
slots=shipSlots{shipIndex};
assigned=state(slots);
itemIDs=inventory.ItemID(assigned);
levels=inventory.Level(assigned);

[~,detail]=support_firepower_fast(selectedShips.ShipID(shipIndex),itemIDs,...
    levels,ships,items,rules);

h=getHitrateOptions(HitrateOptions,shipIndex);
attackerAcc=sum(inventory.Accuracy(assigned));
if isfield(h,'attackerAcc')
    attackerAcc=attackerAcc+h.attackerAcc;
end

expected=evaluateShipExpectedObjective(selectedShips.ShipID(shipIndex),detail,...
    attackerAcc,h,EnemyData,EnemyWeights,ObjectiveWeights);
value=expected.totalObjective;
end

%% ========================================================================
function expected=evaluateShipExpectedObjective(shipID,detail,attackerAcc,h,...
    EnemyData,EnemyWeights,ObjectiveWeights)
% Compute the expected weighted damage-state objective of one support ship.
%
% Target selection is uniform across enemies. EnemyWeights are additional
% multiplicative objective weights and are NOT normalized.

nEnemy=numel(EnemyData.HP);
engagementProbability=[0.15 0.45 0.30 0.10];
attackMultiplier=[1.20 1.00 0.80 0.60];

baseAttackPower=detail.PostCapFirePower(3);
if ~isscalar(baseAttackPower) || ~isfinite(baseAttackPower)
    error('support_firepower_fast returned an invalid PostCapFirePower(3).');
end

hitrateByEnemy=cell(nEnemy,1);
stateProbability=zeros(nEnemy,4); % [Sunk Taiha Chuuha Chip]
engagementStateProbability=zeros(nEnemy,4,4);
enemyObjective=zeros(nEnemy,1);

for e=1:nEnemy
    % support_hitrate is evaluated separately for each enemy because enemy
    % evasion/luck can differ between targets.
    hit=support_hitrate( ...
        h.attackerLevel, ...
        h.attackerLuck, ...
        attackerAcc, ...
        EnemyData.Evasion(e), ...
        EnemyData.Luck(e), ...
        'AttackerMorale',getOpt(h,'AttackerMorale','normal'), ...
        'TargetMorale',getOpt(h,'TargetMorale','normal'), ...
        'Formation',getOpt(h,'Formation','line_ahead'), ...
        'TargetFormation',getOpt(h,'TargetFormation','line_ahead'), ...
        'TargetPosition',getOpt(h,'TargetPosition',1), ...
        'TargetIsDestroyer',getOpt(h,'TargetIsDestroyer',false), ...
        'EventNode',getOpt(h,'EventNode',false));

    hitRate=extractHitRate(hit);
    criticalRate=extractCriticalRate(hit);
    hitrateByEnemy{e}=hit;

    for g=1:4
        attackPower=baseAttackPower*attackMultiplier(g);
        dist=support_damage_distribution( ...
            attackPower,hitRate,criticalRate,...
            EnemyData.HP(e),EnemyData.Armor(e));

        pStates=[dist.sunk,dist.taiha,dist.chuuha,dist.chip];
        engagementStateProbability(e,g,:)=pStates;
        stateProbability(e,:)=stateProbability(e,:)+engagementProbability(g)*pStates;
    end

    stateScore=stateProbability(e,1)*ObjectiveWeights.Sunk + ...
        stateProbability(e,2)*ObjectiveWeights.Taiha + ...
        stateProbability(e,3)*ObjectiveWeights.Chuuha + ...
        stateProbability(e,4)*ObjectiveWeights.Chip;

    enemyObjective(e)=EnemyWeights.Weight(e)/nEnemy*stateScore;
end

expected=struct();
expected.ShipID=shipID;
expected.totalObjective=sum(enemyObjective);
expected.EnemyObjective=enemyObjective;
expected.StateProbability=stateProbability;
expected.EngagementStateProbability=engagementStateProbability;
expected.HitrateByEnemy=hitrateByEnemy;
expected.BasePostCapAttackPower=baseAttackPower;
expected.EnemyWeights=EnemyWeights.Weight(:);
expected.TargetProbability=ones(nEnemy,1)/nEnemy;
expected.EngagementProbability=engagementProbability;
expected.AttackMultiplier=attackMultiplier;
end

%% ========================================================================
function hitRate=extractHitRate(hit)
% Extract the hit probability from support_hitrate output.
fields={'hitRate','hitrate','hitProbability','probabilityToHit'};
for k=1:numel(fields)
    if isfield(hit,fields{k})
        hitRate=hit.(fields{k});
        if isscalar(hitRate) && isfinite(hitRate)
            hitRate=min(1,max(0,hitRate));
            return;
        end
    end
end
error(['support_hitrate output does not contain a scalar hit-rate field. ' ...
    'Expected one of: hitRate, hitrate, hitProbability, probabilityToHit.']);
end

%% ========================================================================
function criticalRate=extractCriticalRate(hit)
% Extract the critical probability conditional on a hit.
fields={'criticalRate','critRate','criticalProbability','critProbability'};
for k=1:numel(fields)
    if isfield(hit,fields{k})
        criticalRate=hit.(fields{k});
        if isscalar(criticalRate) && isfinite(criticalRate)
            criticalRate=min(1,max(0,criticalRate));
            return;
        end
    end
end
error(['support_hitrate output does not contain a scalar critical-rate field. ' ...
    'Expected one of: criticalRate, critRate, criticalProbability, critProbability.']);
end

%% ========================================================================
function validateEnemyInputs(EnemyData,EnemyWeights,ObjectiveWeights)
requiredEnemy={'HP','Armor','Evasion','Luck'};
for k=1:numel(requiredEnemy)
    if ~isfield(EnemyData,requiredEnemy{k})
        error('EnemyData is missing field "%s".',requiredEnemy{k});
    end
end
if ~isfield(EnemyWeights,'Weight')
    error('EnemyWeights must contain field "Weight".');
end
requiredObjective={'Sunk','Taiha','Chuuha','Chip'};
for k=1:numel(requiredObjective)
    if ~isfield(ObjectiveWeights,requiredObjective{k})
        error('ObjectiveWeights is missing field "%s".',requiredObjective{k});
    end
end

n=numel(EnemyData.HP);
for k=1:numel(requiredEnemy)
    x=EnemyData.(requiredEnemy{k});
    if numel(x)~=n || ~isnumeric(x) || any(~isfinite(x(:)))
        error('EnemyData.%s must be a finite numeric vector with one entry per enemy.',requiredEnemy{k});
    end
end
w=EnemyWeights.Weight;
if numel(w)~=n || ~isnumeric(w) || any(~isfinite(w(:))) || any(w(:)<0)
    error('EnemyWeights.Weight must be a finite nonnegative numeric vector with one entry per enemy.');
end
if any(EnemyData.HP(:)<=0) || any(EnemyData.Armor(:)<=0) || any(EnemyData.Evasion(:)<0) || any(EnemyData.Luck(:)<0)
    error('EnemyData requires HP>0, Armor>0, Evasion>=0, and Luck>=0.');
end
for k=1:numel(requiredObjective)
    x=ObjectiveWeights.(requiredObjective{k});
    if ~isscalar(x) || ~isnumeric(x) || ~isfinite(x) || x<0
        error('ObjectiveWeights.%s must be a finite nonnegative scalar.',requiredObjective{k});
    end
end
end

%% ========================================================================
function h=getHitrateOptions(HitrateOptions,shipIndex)
if ~isstruct(HitrateOptions) || ~(numel(HitrateOptions)==1 || numel(HitrateOptions)==6)
    error('HitrateOptions must be a scalar struct or a 6-element struct array.');
end
if numel(HitrateOptions)==1
    h=HitrateOptions;
else
    h=HitrateOptions(shipIndex);
end
required={'attackerLevel','attackerLuck'};
for k=1:numel(required)
    if ~isfield(h,required{k})
        error('HitrateOptions for ship %d is missing field "%s".',shipIndex,required{k});
    end
    x=h.(required{k});
    if ~isnumeric(x) || ~isscalar(x) || ~isfinite(x) || x<0
        error('HitrateOptions.%s for ship %d must be a finite nonnegative scalar.',required{k},shipIndex);
    end
end
end

%% ========================================================================
function value=getOpt(s,field,defaultValue)
if isfield(s,field),value=s.(field);else,value=defaultValue;end
end

%% ========================================================================
function ids=parseTypeIDs(value)
value=string(value);
if ismissing(value) || strlength(value)==0,ids=[];return;end
% Compatibility files normally use comma-separated IDs. Accept several
% common separators to make the rewritten function robust to older files.
txt=char(value);
txt=strrep(txt,';',',');
txt=strrep(txt,' ','');
txt=strrep(txt,'[','');txt=strrep(txt,']','');
txt=strrep(txt,'|',',');
ids=str2double(split(string(txt),','));
ids=ids(~isnan(ids));
end

%% ========================================================================
function path=firstExistingFile(baseDir,candidates)
path='';
for k=1:numel(candidates)
    c=candidates{k};
    if ~isAbsolutePath(c),c=fullfile(baseDir,c);end
    if isfile(c),path=c;return;end
end
% Return the first candidate path so the caller gets a useful error.
if ~isempty(candidates)
    c=candidates{1};
    if ~isAbsolutePath(c),c=fullfile(baseDir,c);end
    path=c;
end
end

%% ========================================================================
function tf=isAbsolutePath(p)
p=char(p);if isempty(p),tf=false;return;end
tf=(p(1)=='/') || (p(1)=='\') || (numel(p)>=2 && p(2)==':');
end

%% ========================================================================
function assignment = orderBestAssignmentForDisplay(assignment,selectedShips)
% Cosmetic ordering of result.bestAssignment. The optimizer state and slot
% identities are not changed.
if isempty(assignment)
    return;
end

rowsOut = cell(6,1);
for s = 1:6
    idx = find(assignment.ShipIndex == s);
    if isempty(idx)
        rowsOut{s} = idx;
        continue;
    end

    stype = selectedShips.SType(s);
    type = double(assignment.EquipmentTypeID(idx));

    if ismember(stype,[8 9 10 2])       % FBB/VBB/DD: guns before radars
        % Lower priority number is displayed first:
        % guns (1,2,3,38) -> non-radar -> radars (12,13,93).
        priority = 2*ones(size(type));
        priority(ismember(type,[1 2 3 38])) = 1;
        priority(ismember(type,[12 13 93])) = 3;
    elseif ismember(stype,[7 11])       % CVL/B: aircraft before radars
        % Carrier aircraft (7,8) -> non-radar -> radars.
        priority = 2*ones(size(type));
        priority(ismember(type,[7 8])) = 1;
        priority(ismember(type,[12 13 93])) = 3;
    else
        priority = ones(size(type));
    end

    % Stable tie-breaking by original row order keeps presentation
    % deterministic within each category.
    [~,ord] = sortrows([priority(:), (1:numel(idx)).'], [1 2]);
    rowsOut{s} = idx(ord);
end

order = vertcat(rowsOut{:});
assignment = assignment(order,:);
end

%% ========================================================================
function out=ternary(tf,a,b)
if tf,out=a;else,out=b;end
end
