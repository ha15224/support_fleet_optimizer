% 保有装備の読み込み
% （require_info_response.txtに艦これAPI require_infoのresponseをコピペ）
get_available_equipment

% 支援艦のIDを入力（戦艦・空母・駆逐のみ）
shipIDs = [954 694 591 707 961 1035];

% 各艦のレベル・運を入力（適当に99/51と設定）
HitrateOptions = struct();
for i = 1:6
    HitrateOptions(i).attackerLevel = 99;
    HitrateOptions(i).attackerLuck = 51;
    HitrateOptions(i).AttackerMorale = 'sparkle';
end

% 各艦の増設有無を設定
ExSlotAvailable = [true true true true true true];

% 敵艦の耐久・装甲・回避・運・目的関数の重みを設定
% 敵艦の数は任意．目的関数では敵選択は一様分布
EnemyData = struct();
EnemyData.HP = ...
    [69 49];
EnemyData.Armor = ...
    [77 48];
EnemyData.Evasion = ...
    [100 83];
EnemyData.Luck = ...
    [80 80];
EnemyWeights = struct();
EnemyWeights.Weight = ...
    [1.0 1.0];

% 目的関数の重みを指定
ObjectiveWeights = struct();
ObjectiveWeights.Sunk   = 10;
ObjectiveWeights.Taiha  = 5;
ObjectiveWeights.Chuuha = 3;
ObjectiveWeights.Chip = 1;

% 最適化を実行
result = optimize_support_equipment_sa_v4( ...
    shipIDs, ...
    ExSlotAvailable, ...
    EquipmentInventory, ...
    HitrateOptions, ...
    EnemyData, ...
    EnemyWeights, ...
    ObjectiveWeights,'UseParfor', true);