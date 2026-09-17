%% Load data
txt = fileread('require_info_response.txt');
% Remove "svdata=" from the beginning
txt = regexprep(txt, '^svdata=', '');
data = jsondecode(txt);

%% Extract equipment
items = data.api_data.api_slot_item;

n = numel(items);

ItemID = zeros(n,1);
Level = zeros(n,1);
Locked = false(n,1);

for k = 1:n
    ItemID(k) = items{k,1}.api_slotitem_id;
    Level(k) = items{k,1}.api_level;
    Locked(k) = logical(items{k,1}.api_locked);
end

OwnedEquipment = table(ItemID, Level, Locked);

[ItemIDLevel, ~, idx] = unique( ...
    [OwnedEquipment.ItemID, OwnedEquipment.Level], ...
    'rows');

Count = accumarray(idx, 1);

ItemID = ItemIDLevel(:,1);
Level  = ItemIDLevel(:,2);

EquipmentInventory = table( ...
    ItemID, ...
    Level, ...
    Count, ...
    'VariableNames', {'ItemID', 'Level', 'Count'});