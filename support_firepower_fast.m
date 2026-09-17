function [supportFP, detail] = support_firepower_fast(shipID, itemIDs, remodels, ships, items, rules)
%SUPPORT_FIREPOWER Calculate support-shelling firepower from kc-web database.
%
% Supports both:
%   1. Normal surface ships
%   2. Carrier-type support ships
%
% Normal ships:
%   supportFP = displayFirePower + 4
%
% Carrier ships:
%   supportFP = floor( ...
%       1.5 * (displayFirePower ...
%            + displayTorpedo ...
%            + floor(1.3 * displayBomber) - 1) ...
%       ) + 55
%
% The display stats include:
%   ship base stat
%   + raw equipment stat
%   + applicable kc-web equipment-fit bonuses
%
% Equipment improvement bonuses (Item.bonusFire) are NOT included in
% getSupportFirePower().

% if nargin < 4 || isempty(dbFile)
%     dbFile = fullfile(fileparts(mfilename('fullpath')), ...
%                       'kc_firepower_database.xlsx');
% end

itemIDs = itemIDs(:);
remodels = remodels(:);

if numel(itemIDs) ~= numel(remodels)
    error('itemIDs and remodels must have the same length.');
end

%% Load database

% ships = readtable(dbFile, 'Sheet', 'Ships', 'TextType', 'string');
% items = readtable(dbFile, 'Sheet', 'Equipment', 'TextType', 'string');
% rules = readtable(dbFile, 'Sheet', 'FP_BonusRules');

% Fields that may be empty must always be treated as strings.
textFields = { ...
    'TriggerTypes', ...
    'TriggerItemIDs', ...
    'ShipIDs', ...
    'ShipClasses', ...
    'ShipCountries', ...
    'ShipTypes', ...
    'ShipBaseIDs', ...
    'RequiresTypes', ...
    'RequiresItemIDs', ...
    'RequiresItemIDs2' ...
    };

for k = 1:numel(textFields)
    f = textFields{k};
    rules.(f) = string(rules.(f));
    rules.(f)(ismissing(rules.(f))) = "";
end

%% Find ship

sidx = find(ships.ShipID == shipID, 1);

if isempty(sidx)
    error('Unknown ship ID %d.', shipID);
end

ship = ships(sidx,:);

%% Find equipment

selected = zeros(numel(itemIDs), 1);

for k = 1:numel(itemIDs)

    idx = find(items.ItemID == itemIDs(k), 1);

    if isempty(idx)
        error('Unknown equipment ID %d.', itemIDs(k));
    end

    selected(k) = idx;
end

eq = items(selected,:);

%% Raw equipment stats

baseItemFP = sum(eq.FirePower);

% These are needed for the carrier formula.
baseItemTP = sum(eq.Torpedo);
baseItemBomber = sum(eq.Bomber);

%% Evaluate equipment-fit firepower bonuses

% Count radar/equipment conditions.
antiAirRadarCount = sum(eq.IconTypeID == 11 & eq.AA > 1);
surfaceRadarCount = sum(eq.IconTypeID == 11 & eq.Scout > 4);
accuracyRadarCount = sum(eq.IconTypeID == 11 & eq.Accuracy >= 8);

bonusFP = 0;
applied = strings(0,1);

for rr = 1:height(rules)

    r = rules(rr,:);

    %% Trigger equipment

    triggerMask = false(numel(itemIDs),1);

    if strlength(r.TriggerTypes) > 0
        triggerTypes = parseIDs(r.TriggerTypes);
        triggerMask = triggerMask | ...
            ismember(eq.APITypeID, triggerTypes);
    end

    if strlength(r.TriggerItemIDs) > 0
        triggerIDs = parseIDs(r.TriggerItemIDs);
        triggerMask = triggerMask | ...
            ismember(eq.ItemID, triggerIDs);
    end

    fit = find(triggerMask);

    if isempty(fit)
        continue
    end

    %% Ship conditions

    if ~conditionMatchesShip(r, ship)
        continue
    end

    %% Radar requirements

    if r.RequiresAARadar && antiAirRadarCount == 0
        continue
    end

    if r.RequiresSurfaceRadar && surfaceRadarCount == 0
        continue
    end

    if r.RequiresAccuracyRadar && accuracyRadarCount == 0
        continue
    end

    %% requiresType

    if strlength(r.RequiresTypes) > 0

        reqTypes = parseIDs(r.RequiresTypes);

        if ~any(ismember(eq.APITypeID, reqTypes))
            continue
        end
    end

    %% requiresId / requiresIdLevel / requiresIdNum

    if strlength(r.RequiresItemIDs) > 0

        req = parseIDs(r.RequiresItemIDs);

        t = find(ismember(eq.ItemID, req));

        if r.RequiresItemCount > 0 && ...
                numel(t) < r.RequiresItemCount
            continue
        end

        if r.RequiresItemMinRemodel > 0 && ...
                ~any(remodels(t) >= r.RequiresItemMinRemodel)
            continue
        end

        if isempty(t)
            continue
        end

        %% Second required equipment group

        if strlength(r.RequiresItemIDs2) > 0

            req2 = parseIDs(r.RequiresItemIDs2);

            t2 = find(ismember(eq.ItemID, req2));

            if isempty(t2)
                continue
            end

            if r.RequiresItemMinRemodel2 > 0 && ...
                    ~any(remodels(t2) >= r.RequiresItemMinRemodel2)
                continue
            end
        end
    end

    %% Trigger improvement/count conditions

    if r.TriggerMinRemodel > 0

        fitRemodel = remodels(fit);

        fit = fit(fitRemodel >= r.TriggerMinRemodel);

        if isempty(fit)
            continue
        end

        if r.TriggerMinCount > 0

            if numel(fit) < r.TriggerMinCount
                continue
            end

            % num specified -> apply once
            nApply = 1;

        else

            % No num -> cumulative
            nApply = numel(fit);

        end

    elseif r.TriggerMinCount > 0

        if numel(fit) < r.TriggerMinCount
            continue
        end

        nApply = 1;

    else

        nApply = numel(fit);

    end

    %% Apply FP bonus

    add = nApply * r.FirePowerBonus;

    bonusFP = bonusFP + add;

    applied(end+1,1) = sprintf( ...
        'Group %d Rule %d: %+g FP x %d', ...
        r.GroupID, r.RuleID, r.FirePowerBonus, nApply); %#ok<AGROW>

end

%% Display stats

displayFirePower = ship.MaxFirePower ...
                 + baseItemFP ...
                 + bonusFP;

displayTorpedo = ship.MaxTorpedo ...
               + baseItemTP;

displayBomber = ship.MaxBomber ...
              + baseItemBomber;

%% Carrier / special support formula

% kc-web:
%
% if (this.data.isCV ||
%     ([717].includes(this.data.id) &&
%      this.items.some(v =>
%          v.data.isAttacker && !v.data.isAswPlane)))
%
%     supportFirePower =
%         Math.floor(
%             1.5 * (
%                 this.displayStatus.firePower
%                 + this.displayStatus.torpedo
%                 + Math.floor(1.3 * this.displayStatus.bomber)
%                 - 1
%             )
%         ) + 55;
%
% else
%
%     supportFirePower =
%         this.displayStatus.firePower + 4;

isCarrier = ship.IsCV;

% Special ship ID 717 condition.
isSpecialCarrier = false;

if ship.ShipID == 717

    % Check whether at least one equipped aircraft is an attacker
    % and is not an ASW plane.
    isAttacker = eq.IsAttacker;
    isAswPlane = eq.IsAswPlane;

    isSpecialCarrier = any(isAttacker & ~isAswPlane);
end

if isCarrier || isSpecialCarrier

    supportFP = floor( ...
        1.5 * ( ...
            displayFirePower ...
            + displayTorpedo ...
            + floor(1.3 * displayBomber) ...
            - 1 ...
        ) ...
    ) + 55;

    formulaType = "carrier";

else

    supportFP = displayFirePower + 4;

    formulaType = "normal";

end

%% Detail output

detail = struct();

detail.shipBaseFP = ship.MaxFirePower;

detail.itemBaseFP = baseItemFP;

detail.equipmentBonusFP = bonusFP;

% Kept for diagnostic purposes only.
% It is NOT used in supportFP.
detail.remodelFP = 0;

detail.displayFirePower = displayFirePower;
detail.displayTorpedo = displayTorpedo;
detail.displayBomber = displayBomber;

detail.supportConstant = 4;

detail.isCarrier = isCarrier;
detail.isSpecialCarrier = isSpecialCarrier;
detail.formulaType = formulaType;

detail.supportFP = supportFP;

detail.appliedBonusRules = applied;

detail.itemIDs = itemIDs;
detail.remodels = remodels;

% ------------------------------------------------------------
% Post-cap firepower for each engagement
% ------------------------------------------------------------

engagements = {'RedT', 'HeadOn', 'Parallel', 'GreenT'};

% Engagement modifiers used before the 170 cap
engagementModifier = [
    0.6;    % Red T
    0.8;    % Head-on
    1.0;    % Parallel
    1.2     % Green T
];

% Pre-cap firepower for each engagement
preCapFirePower = supportFP .* engagementModifier;

% Apply the 170 firepower cap
postCapFirePower = zeros(size(preCapFirePower));

for i = 1:numel(preCapFirePower)
    if preCapFirePower(i) <= 170
        postCapFirePower(i) = preCapFirePower(i);
    else
        postCapFirePower(i) = 170 + sqrt(preCapFirePower(i) - 170);
    end
end

% Flooring
preCapFirePower = floor(preCapFirePower);
postCapFirePower = floor(postCapFirePower);

% Store results
% detail.Engagement = engagements;
% detail.EngagementModifier = engagementModifier;
detail.PreCapFirePower = preCapFirePower;
detail.PostCapFirePower = postCapFirePower;


end


%% ========================================================================
function ids = parseIDs(s)

if isempty(s) || ismissing(string(s)) || strlength(string(s)) == 0
    ids = [];
    return
end

s = string(s);

ids = str2double(split(s, ";"));
ids = ids(~isnan(ids));

end


%% ========================================================================
function ok = conditionMatchesShip(r, ship)

ok = true;

if strlength(r.ShipIDs) > 0 && ...
        ~ismember(ship.ShipID, parseIDs(r.ShipIDs))
    ok = false;
    return
end

if strlength(r.ShipClasses) > 0 && ...
        ~ismember(ship.CType, parseIDs(r.ShipClasses))
    ok = false;
    return
end

if strlength(r.ShipCountries) > 0

    % kc-web represents shipCountry conditions using the relevant
    % ship class/ctype identifiers.
    if ~ismember(ship.CType, parseIDs(r.ShipCountries))
        ok = false;
        return
    end
end

if strlength(r.ShipTypes) > 0 && ...
        ~ismember(ship.SType, parseIDs(r.ShipTypes))
    ok = false;
    return
end

if strlength(r.ShipBaseIDs) > 0 && ...
        ~ismember(ship.OriginalID, parseIDs(r.ShipBaseIDs))
    ok = false;
    return
end

end