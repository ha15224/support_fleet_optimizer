艦これの支援艦隊を任意の目的関数で最適化します．（実行ファイルはmain.m）

最適化アルゴリズムらくらく支援艦隊様の焼きなまし法を参考にしています

計算負荷はかなり重いです（時間は数十分程度）

以下，AI生成のコード概要

# Support Fleet Equipment Optimizer

艦隊これくしょん -艦これ- の**支援艦隊における装備編成を最適化する MATLAB プロジェクト**です。

所持装備、装備改修値、艦娘の能力値、敵艦の HP・装甲・回避・運、および装備シナジーを考慮し、支援砲撃による期待ダメージを最大化する装備配置を**焼きなまし法（Simulated Annealing; SA）**によって探索します。

本プロジェクトでは、支援艦隊の火力・命中率だけでなく、敵艦の撃沈・大破・中破・小破・カスダメといったダメージ状態まで確率的に評価します。

---

## Features

### 支援火力計算

`support_firepower_fast.m` により、艦娘と装備から支援砲撃火力を計算します。

* 艦娘の素火力
* 装備の火力・雷装・爆装
* 装備シナジーによる火力補正
* 艦種ごとの支援火力計算式
* 空母系の特殊な支援火力計算式
* 特定艦娘に対する特殊条件
* 装備改修値を利用した装備シナジー条件
* レーダー装備の条件
* 必須装備・装備種条件
* 装備数条件

などを考慮します。

また、以下の交戦形態について 170 キャップを適用した火力を計算します。

| 交戦形態 | 火力倍率 |
| ---- | ---: |
| T字有利 | 1.20 |
| 同航戦  | 1.00 |
| 反航戦  | 0.80 |
| T字不利 | 0.60 |

---

## 支援命中率計算

`support_hitrate.m` は支援砲撃の命中率を計算します。

以下の要素を考慮します。

* 攻撃側艦娘のレベル
* 攻撃側の運
* 装備命中値
* 攻撃側の士気
* 攻撃側陣形
* 敵艦の回避
* 敵艦の運
* 敵陣形
* 警戒陣
* 警戒陣における敵艦位置
* 駆逐艦に対する警戒陣補正
* イベント海域における警戒陣補正
* 回避値のソフトキャップ

出力には以下の情報が含まれます。

```matlab
result.hitPercent
result.criticalPercent
result.normalHitPercent
result.missPercent
```

---

## ダメージ分布計算

`support_damage_distribution.m` は、支援砲撃のダメージ状態を確率的に評価します。

敵装甲の乱数を全列挙することで、以下の状態について確率分布を計算します。

* `Sunk` — 撃沈
* `Taiha` — 大破
* `Chuuha` — 中破
* `Shouha` — 小破
* `Chip` — カスダメ / Scratch

通常攻撃・クリティカル攻撃を分離して計算し、最終的に命中率とクリティカル率を用いて無条件確率分布を構築します。

出力例：

```matlab
dist.sunk
dist.taiha
dist.chuuha
dist.shouha
dist.chip
dist.miss
dist.expectedDamage
```

---

# Optimization

## Simulated Annealing

メインの最適化アルゴリズムは `optimize_support_equipment_sa_v4.m` です。

単純な装備総当たりではなく、以下の前処理・探索空間削減を行ったうえで焼きなまし法を実行します。

### 1. Dominance reduction

他の装備に対して明らかに優位性を持たない装備候補を探索空間から除外します。

---

### 2. Forced assignment reduction

以下のような、実質的に割り当てが決まっているスロットを前処理で確定します。

* 候補装備が1種類しかないスロット
* 在庫数によって割り当てが強制される装備
* 飽和した装備・スロットの組み合わせ

これにより、SA が探索する変数数を削減します。

---

### 3. Equivalent-slot reduction

同一艦内などで、装備候補集合が等価なスロットをグループ化します。

装備を入れ替えても目的関数が変化しない対称な解を同一視することで、探索空間を削減します。

---

### 4. Initial solution improvement

SA 開始前に、各艦について簡易的な coordinate/local optimization を実行します。

これにより、完全なランダム初期解から探索を開始する場合と比較して、初期解の品質を改善します。

---

### 5. Multiple independent SA runs

複数の独立した SA を実行し、その中で最も目的関数が高い解を採用します。

```text
Initial solution
      │
      ├── SA run 1
      ├── SA run 2
      ├── SA run 3
      ├── ...
      └── SA run N
             │
             ▼
        Best solution
```

---

### 6. Parallel execution

Parallel Computing Toolbox が利用可能な場合、独立した SA run を `parfor` によって並列実行できます。

```matlab
result = optimize_support_equipment_sa_v4( ...
    shipIDs, ...
    ExSlotAvailable, ...
    EquipmentInventory, ...
    HitrateOptions, ...
    EnemyData, ...
    EnemyWeights, ...
    ObjectiveWeights, ...
    'UseParfor', true);
```

独立した SA run はそれぞれ異なる乱数 seed を使用します。

---

## Objective Function

最適化対象は、6隻の支援艦それぞれについて計算された期待ダメージ状態スコアの合計です。

敵艦については指定された重みを使用し、敵艦の選択確率を考慮します。

概念的には、

```text
Objective
 =
 Σ ship
   Σ enemy
     EnemyWeight
     × Σ engagement
         EngagementProbability
         × StateScore
```

です。

状態スコアは、

```text
StateScore =
    SunkWeight  × P(Sunk)
  + TaihaWeight × P(Taiha)
  + ChuuhaWeight × P(Chuuha)
  + ChipWeight  × P(Chip)
```

として計算されます。

したがって、単純な「最大火力」ではなく、

> **指定された敵編成に対して、支援砲撃でどの程度の撃沈・大破・中破・カスダメを期待できるか**

を目的関数として装備編成を探索します。

---

# Equipment Slot Constraints

装備可能スロットは、

```text
kc_ship_slot_equipment_type_lookup_v2.xlsx
```

を使用して決定します。

さらに艦種ごとの支援艦隊用制約を適用します。

### 戦艦・航空戦艦・重巡系

通常スロットでは、データベースに基づく装備可能カテゴリを使用します。

増設スロットでは、主に以下のカテゴリを候補とします。

* 電探
* 三式弾系
* 水上艦要員

---

### 軽空母・正規空母系

支援砲撃を成立させるため、**第1通常スロットには艦上爆撃機または艦上攻撃機を必ず配置**します。

つまり、第1スロットについては通常のスロット互換表より優先して、

```text
艦上爆撃機 (type 7)
艦上攻撃機 (type 8)
```

のみを候補とします。

レーダーなどを第1スロットに割り当てることはできません。

増設スロットでは、

* 航空要員
* 電探

などを候補とします。

---

### 駆逐艦

通常スロットでは、

* 小口径主砲
* 電探
* 水上艦要員

などの支援艦隊向け装備カテゴリを考慮します。

増設スロットについても、艦娘ごとの互換性を `ExpansionItemLookup` から確認します。

---

# Inventory Handling

ユーザーが所持している装備は、

```text
require_info_response.txt
```

から読み込みます。

このファイルには艦これ API の `svdata=` 形式のレスポンスを保存してください。

`get_available_equipment.m` がレスポンスを解析し、

```text
ItemID
Level
Count
```

という形式の `EquipmentInventory` テーブルを生成します。

例えば、

```text
ItemID   Level   Count
-----    -----   -----
12       10      3
13        7      2
501      10      1
```

のように、同一装備・同一改修値の装備をまとめます。

---

# Database

プロジェクトには以下のデータベースが含まれています。

## `kc_firepower_database_v2.xlsx`

主に以下の情報を格納します。

### Ships

艦娘データ。

* Ship ID
* 艦名
* 艦種
* 艦型
* 国
* 素火力
* 雷装
* 爆装
* その他の判定用情報

### Equipment

装備データ。

* 装備 ID
* 装備名
* 装備種別
* 火力
* 雷装
* 爆装
* 命中
* 対空
* 索敵
* 艦攻 / 艦爆判定
* 対潜機判定
* その他

### FP_BonusRules

装備シナジーによる火力補正ルール。

以下のような条件を扱います。

* 装備種別
* 特定装備
* 艦種
* 艦型
* 艦娘 ID
* 改修値
* 必須装備
* 必要装備数
* レーダー条件
* 複数条件

---

## `kc_ship_slot_equipment_type_lookup_v2.xlsx`

艦娘ごとの装備スロット互換性を定義します。

主なシート：

```text
SlotCompatibility
ExpansionItemLookup
```

`SlotCompatibility` は通常スロットの装備可能カテゴリを、

`ExpansionItemLookup` は増設スロットに装備可能な具体的装備を定義します。

---

# Project Structure

```text
supportfleet/
│
├── main.m
│
├── optimize_support_equipment_sa_v4.m
│
├── support_firepower_fast.m
├── support_hitrate.m
├── support_damage_distribution.m
├── get_available_equipment.m
│
├── kc_firepower_database_v2.xlsx
├── kc_ship_slot_equipment_type_lookup_v2.xlsx
│
├── require_info_response.txt
│
└── legacy/
    ├── optimize_support_equipment_sa.m
    ├── optimize_support_equipment_sa_old.m
    ├── optimize_support_equipment_sa_v2.m
    ├── optimize_support_equipment_sa_v3.m
    └── optimize_support_equipment_sa_v3_expansion.m
```

`legacy/` には旧バージョンの最適化アルゴリズムを保存しています。

現在のメイン実装は、

```text
optimize_support_equipment_sa_v4.m
```

です。

---

# Requirements

## MATLAB

MATLAB が必要です。

本プロジェクトでは以下の MATLAB 機能を使用します。

* `readtable`
* `jsondecode`
* `inputParser`
* `containers.Map`
* `parfor`（オプション）

また、`UseParfor = true` とする場合は **Parallel Computing Toolbox** が必要です。

---

# Usage

## 1. API レスポンスを用意

艦これの `require_info` 相当のレスポンスを取得し、

```text
require_info_response.txt
```

としてプロジェクトディレクトリに配置します。

ファイルは通常、

```text
svdata={"api_data": ...}
```

のような形式になります。

---

## 2. Equipment inventory を生成

MATLAB で、

```matlab
get_available_equipment
```

を実行します。

これにより、`require_info_response.txt` から所持装備を読み取り、

```matlab
EquipmentInventory
```

を作成します。

---

## 3. Optimization

`main.m` を実行します。

```matlab
main
```

現在の `main.m` では、6隻の支援艦、敵艦データ、命中条件、目的関数の重みなどを設定し、

```matlab
optimize_support_equipment_sa_v4(...)
```

を呼び出します。

---

# Example Configuration

`main.m` の基本的な構成は以下の通りです。

```matlab
shipIDs = [954 694 591 707 961 1035];

HitrateOptions = struct();

for i = 1:6
    HitrateOptions(i).attackerLevel = 99;
    HitrateOptions(i).attackerLuck = 51;
    HitrateOptions(i).AttackerMorale = 'sparkle';
end

ExSlotAvailable = ...
    [true true true true true true];

EnemyData.HP = [69 49];
EnemyData.Armor = [77 48];
EnemyData.Evasion = [100 83];
EnemyData.Luck = [80 80];

EnemyWeights.Weight = [1.0 1.0];

ObjectiveWeights.Sunk   = 10;
ObjectiveWeights.Taiha  = 5;
ObjectiveWeights.Chuuha = 3;
ObjectiveWeights.Chip   = 1;
```

その後、

```matlab
result = optimize_support_equipment_sa_v4( ...
    shipIDs, ...
    ExSlotAvailable, ...
    EquipmentInventory, ...
    HitrateOptions, ...
    EnemyData, ...
    EnemyWeights, ...
    ObjectiveWeights, ...
    'UseParfor', true);
```

として最適化します。

---

# Important Options

`optimize_support_equipment_sa_v4` では以下のオプションを変更できます。

| Option                          |     Default | Description                 |
| ------------------------------- | ----------: | --------------------------- |
| `NumStarts`                     |        `10` | 独立 SA 実行回数                  |
| `MaxIterations`                 |      `5000` | 各 SA の最大反復回数                |
| `InitialTemperature`            |         `1` | 初期温度                        |
| `CoolingRate`                   |      `0.90` | 冷却率                         |
| `FinalTemperature`              |      `5e-4` | 最終温度                        |
| `SwapProbability`               |      `0.25` | swap move の確率               |
| `RandomSeed`                    | `'shuffle'` | 乱数 seed                     |
| `Verbose`                       |      `true` | ログ出力                        |
| `RandomCandidateTrials`         |         `6` | ランダム候補試行数                   |
| `HillClimbIterations`           |      `2000` | 最終 hill climbing 回数         |
| `HillClimbCandidateTrials`      |         `6` | hill climbing 候補数           |
| `InitialJitterProbability`      |      `0.15` | 初期解 jitter 確率               |
| `SingleShipIterations`          |       `100` | 初期 single-ship optimization |
| `SingleShipCandidateTrials`     |         `8` | single-ship 候補数             |
| `UseParfor`                     |     `false` | SA runs の並列化                |
| `EnableDominanceReduction`      |      `true` | dominance reduction         |
| `EnableForcedReduction`         |      `true` | forced assignment reduction |
| `EnableEquivalentSlotReduction` |      `true` | equivalent-slot reduction   |

例えば、より長く探索する場合：

```matlab
result = optimize_support_equipment_sa_v4( ...
    shipIDs, ...
    ExSlotAvailable, ...
    EquipmentInventory, ...
    HitrateOptions, ...
    EnemyData, ...
    EnemyWeights, ...
    ObjectiveWeights, ...
    'NumStarts', 50, ...
    'MaxIterations', 10000, ...
    'UseParfor', true);
```

---

# Output

最適化結果は `result` 構造体として返されます。

主なフィールド：

```matlab
result.bestObjective
result.bestAssignment
result.bestShips
result.shipResults
result.shipObjective
result.history
result.allRuns
result.preprocessing
result.options
result.EnemyData
result.EnemyWeights
result.ObjectiveWeights
result.ExSlotAvailable
result.slotMetadata
result.EngagementOptions
```

## Best Assignment

```matlab
result.bestAssignment
```

には最適解として選択された装備が格納されます。

主な列：

```text
ShipIndex
ShipID
ShipName
Slot
IsExpansionSlot
ItemID
ItemName
Level
EquipmentTypeID
```

例えば、

```text
ShipName    Slot    ItemName              Level
------------------------------------------------
Battleship  1       Main Gun              10
Battleship  2       Main Gun               9
Battleship  3       Radar                 10
Battleship  4       Radar                  7
Battleship  0       Expansion Radar       10
```

のような形になります。

---

# Interpretation of the Objective

このプログラムの目的関数は、一般的な「装備火力最大化」とは異なります。

例えば、

```matlab
ObjectiveWeights.Sunk   = 10;
ObjectiveWeights.Taiha  = 5;
ObjectiveWeights.Chuuha = 3;
ObjectiveWeights.Chip   = 1;
```

とした場合、

```text
撃沈 > 大破 > 中破 > カスダメ
```

という**数値化された目的関数**になります。

したがって、結果として得られる装備編成は、

> 「最大火力になる編成」

ではなく、

> 「指定した敵編成・命中条件・交戦形態分布のもとで、指定したダメージ状態の期待スコアを最大化する編成」

です。

ObjectiveWeights を変更することで、異なる最適化基準を調べることができます。

---

# Notes and Limitations

### 1. ゲーム内計算式の再現

本プロジェクトは、コード内に実装された支援砲撃計算式を基準として計算します。

ゲーム本体の仕様変更があった場合、データベースおよび計算式の更新が必要です。

---

### 2. Damage distribution

`support_damage_distribution.m` は装甲乱数を列挙してダメージ分布を計算します。

一方、実際のゲーム内のすべての戦闘処理をシミュレーションしているわけではありません。

特に、実際の Scratch / カスダメ処理などと、本プロジェクトにおける `Chip` の定義には注意が必要です。

---

### 3. Target selection

敵艦については `EnemyWeights` によって重み付けします。

デフォルトでは、

```matlab
EnemyWeights.Weight = [1.0 1.0];
```

のように、指定された敵艦を均等に扱います。

実際のゲーム内ターゲット選択確率を完全に再現するものではありません。

---

### 4. Engagement formation

T字有利・同航戦・反航戦・T字不利の確率は、現在の実装では固定されています。

```text
T字有利 : 0.15
同航戦  : 0.45
反航戦  : 0.30
T字不利 : 0.10
```

これらは `result.EngagementOptions` から確認できます。

---

### 5. Optimization is stochastic

SA は確率的最適化手法であるため、単一の実行結果が数学的な大域最適解であることを保証しません。

そのため、

```matlab
NumStarts
```

を増やして独立した探索を複数回行い、得られた解を比較する設計になっています。

---

# Legacy Implementations

`legacy/` には過去のアルゴリズムが保存されています。

```text
optimize_support_equipment_sa.m
optimize_support_equipment_sa_old.m
optimize_support_equipment_sa_v2.m
optimize_support_equipment_sa_v3.m
optimize_support_equipment_sa_v3_expansion.m
```

これらはアルゴリズムの発展過程を保存する目的で含まれており、現在の通常利用では `v4` を使用してください。

---

# Development History

最適化アルゴリズムは概ね以下のように発展しています。

```text
Basic Simulated Annealing
        │
        ▼
     SA v2
        │
        ▼
     SA v3
        │
        ├── Enemy-aware objective
        ├── Damage-state objective
        └── Expansion-slot support
        │
        ▼
     SA v4
        │
        ├── Dominance reduction
        ├── Forced assignment
        ├── Equivalent-slot reduction
        ├── Improved initialization
        ├── Incremental objective evaluation
        ├── Local improvement
        └── Optional PARFOR parallelization
```

---

# License

このプロジェクトのライセンスは未指定です。

ゲームデータ・装備データ・計算式の利用および再配布については、それぞれのデータソースおよびゲーム運営元の利用規約・権利関係を確認してください。
