function dist = support_damage_distribution( ...
    postCapAttackPower, hitRate, criticalRate, enemyHP, enemyArmor)
%SUPPORT_DAMAGE_DISTRIBUTION
% Calculate the exact probability distribution of damage states for a
% support-shelling attack.
%
% INPUTS
%   postCapAttackPower : post-cap attack power before critical modifier
%   hitRate            : probability of hitting, [0,1]
%   criticalRate       : probability of critical, [0,1]
%                        Critical rate is conditional on the attack hitting.
%   enemyHP            : enemy's current HP
%   enemyArmor         : enemy's displayed armor
%
% OUTPUT
%   dist : structure containing probabilities and expected values.
% If attack power <= DEF, the attack is classified as CHIP.
%
% Damage-state classification:
%   Sunk  : damage >= enemyHP
%   Taiha : remaining HP <= 25% of enemyHP
%   Chuuha: remaining HP <= 50% of enemyHP
%   Shouha: remaining HP <= 75% of enemyHP
%
% NOTE:
%   The returned "chip" probability is specifically the probability that
%   attack power is lower than the generated armor value, as requested.
%   Actual KanColle scratch damage is not modeled here.

    %% ------------------------------------------------------------
    % Input validation
    % -------------------------------------------------------------

    validateattributes(postCapAttackPower, {'numeric'}, ...
        {'scalar', 'nonnegative', 'finite'});

    validateattributes(hitRate, {'numeric'}, ...
        {'scalar', 'nonnegative', 'finite'});

    validateattributes(criticalRate, {'numeric'}, ...
        {'scalar', 'nonnegative', 'finite'});

    validateattributes(enemyHP, {'numeric'}, ...
        {'scalar', 'positive', 'finite'});

    validateattributes(enemyArmor, {'numeric'}, ...
        {'scalar', 'positive', 'finite'});


    %% ------------------------------------------------------------
    % Attack power
    % ------------------------------------------------------------

    % Critical attack power is calculated from the floored
    % normal attack power.
    criticalAttackPower = floor(1.5 * postCapAttackPower);


    %% ------------------------------------------------------------
    % Armor randomization
    % ------------------------------------------------------------

    % Generated armor:
    %
    %   D = 0.7 * Armor + 0.6 * r
    %
    % where
    %
    %   r = 0, 1, ..., floor(Armor)-1
    %
    % The generated armor itself is NOT floored.
    nArmorRolls = floor(enemyArmor);

    armorRandom = 0:(nArmorRolls - 1);

    generatedArmor = ...
        0.7 * enemyArmor + 0.6 * armorRandom;


    %% ------------------------------------------------------------
    % Damage for each armor roll
    % ------------------------------------------------------------

    % Damage is floored AFTER subtracting the generated armor.
    normalDamage = ...
        floor(postCapAttackPower - generatedArmor);

    criticalDamage = ...
        floor(criticalAttackPower - generatedArmor);

    % Damage cannot be negative.
    normalDamage = max(normalDamage, 0);
    criticalDamage = max(criticalDamage, 0);

    %% ------------------------------------------------------------
    % Classification function
    % ------------------------------------------------------------

    % FleetHub classifies a hit as Scratch when the calculated damage
    % value is zero. Therefore, classification is based on the actual
    % damage value rather than directly on attackPower < generatedArmor.

    classifyDamage = @(damage) ...
        classify_damage(damage, enemyHP);

    normalClass = classifyDamage(normalDamage);

    criticalClass = classifyDamage(criticalDamage);


    %% ------------------------------------------------------------
    % Conditional distributions given a hit
    % ------------------------------------------------------------

    categories = { ...
        'Sunk', ...
        'Taiha', ...
        'Chuuha', ...
        'Shouha', ...
        'Chip'};

    normalProb = zeros(1,5);
    criticalProb = zeros(1,5);

    for k = 1:5
        normalProb(k) = mean(normalClass == k);
        criticalProb(k) = mean(criticalClass == k);
    end


    %% ------------------------------------------------------------
    % Combine normal and critical hits
    %
    % criticalRate is conditional on the attack being a hit.
    %
    % P(category) =
    %   P(hit) * [
    %       P(crit | hit)  * P(category | crit)
    %       +
    %       P(normal | hit) * P(category | normal)
    %   ]
    %
    % Misses are not assigned to any damage category.
    % ------------------------------------------------------------

    unconditionalDistribution = ...
        (hitRate - criticalRate) * normalProb + ...
        criticalRate * criticalProb;

    %% ------------------------------------------------------------
    % Output
    % ------------------------------------------------------------

    dist = struct();

    % % Inputs
    % dist.postCapAttackPower = postCapAttackPower;

    dist.normalClass = normalClass;
    dist.criticalClass = criticalClass;

    % FleetHub applies floor() after the 170 attack-power cap.
    dist.normalAttackPower = postCapAttackPower;
    dist.criticalAttackPower = criticalAttackPower;

    dist.hitRate = hitRate;
    dist.criticalRate = criticalRate;

    dist.enemyHP = enemyHP;
    dist.enemyArmor = enemyArmor;

    % Armor rolls
    dist.generatedArmor = generatedArmor;
    dist.nArmorRolls = nArmorRolls;

    % Damage distributions
    dist.normalDamage = normalDamage;
    dist.criticalDamage = criticalDamage;

    % Conditional on hitting
    dist.normal = normalProb;
    dist.critical = criticalProb;
    % dist.conditionalHit = conditionalHitDistribution;

    % Including misses
    dist.unconditional = unconditionalDistribution;

    % Named probabilities
    dist.sunk = unconditionalDistribution(1);
    dist.taiha = unconditionalDistribution(2);
    dist.chuuha = unconditionalDistribution(3);
    dist.shouha = unconditionalDistribution(4);
    dist.chip = unconditionalDistribution(5);

    % Probability of a miss
    dist.miss = 1 - hitRate;

    % Probability that a hit produces actual positive damage
    dist.nonChipHit = ...
        hitRate * (1 - unconditionalDistribution(5));

    % Expected damage conditional on hitting
    dist.expectedDamageGivenHit = ...
        (1 - criticalRate) * mean(normalDamage) + ...
        criticalRate * mean(criticalDamage);

    % Expected damage including misses
    dist.expectedDamage = ...
        hitRate * dist.expectedDamageGivenHit;

    % Labels
    dist.labels = categories;

end


%% ========================================================================
% Local function
% ========================================================================

function class = classify_damage(damage, enemyHP)

    % FleetHub damage classification:
    %
    %   damage == 0       -> Scratch / Chip
    %   damage >= HP      -> Sunk
    %   remaining HP <=25% -> Taiha
    %   remaining HP <=50% -> Chuuha
    %   remaining HP <=75% -> Shouha
    %
    % The damage supplied here is already the result of:
    %
    %   floor(attackPower - generatedArmor)
    %
    % with a lower bound of zero.

    class = zeros(size(damage));

    %% ------------------------------------------------------------
    % CHIP / SCRATCH
    % ------------------------------------------------------------

    chip = damage == 0;

    class(chip) = 5;


    %% ------------------------------------------------------------
    % Positive damage
    % ------------------------------------------------------------

    positive = damage > 0;

    d = damage(positive);


    %% ------------------------------------------------------------
    % Sunk
    % ------------------------------------------------------------

    sunk = d >= enemyHP;

    tmp = zeros(size(d));

    tmp(sunk) = 1;


    %% ------------------------------------------------------------
    % Remaining HP
    % ------------------------------------------------------------

    remainingHP = enemyHP - d;


    %% ------------------------------------------------------------
    % Taiha
    %
    % Remaining HP <= 25%
    % ------------------------------------------------------------

    taiha = ~sunk & ...
        remainingHP <= 0.25 * enemyHP;

    tmp(taiha) = 2;


    %% ------------------------------------------------------------
    % Chuuha
    %
    % Remaining HP <= 50%
    % ------------------------------------------------------------

    chuuha = ~sunk & ~taiha & ...
        remainingHP <= 0.50 * enemyHP;

    tmp(chuuha) = 3;


    %% ------------------------------------------------------------
    % Shouha
    %
    % Remaining HP <= 75%
    % ------------------------------------------------------------

    shouha = ~sunk & ~taiha & ~chuuha & ...
        remainingHP <= 0.75 * enemyHP;

    tmp(shouha) = 4;


    %% ------------------------------------------------------------
    % Assign positive-damage classifications
    % ------------------------------------------------------------

    class(positive) = tmp;

end
