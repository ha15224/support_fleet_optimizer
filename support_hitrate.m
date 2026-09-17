function result = support_hitrate(attackerLevel, attackerLuck, ...
    attackerAcc, enemyEvasion, enemyLuck, varargin)
%SUPPORT_HITRATE Calculate FleetHub-style support shelling hit rate.
%
%   result = support_hitrate(attackerLevel, attackerLuck, attackerAcc, ...
%       enemyEvasion, enemyLuck)
%
%   Required inputs
%   ----------------
%   attackerLevel : Attacking ship level
%   attackerLuck  : Attacking ship Luck
%   attackerAcc   : Sum of accuracy values from equipment
%   enemyEvasion  : Enemy ship Evasion
%   enemyLuck     : Enemy ship Luck
%
%   Optional name-value inputs
%   --------------------------
%   'AttackerMorale' : 'sparkle', 'normal', 'orange', 'red'
%                       Default: 'normal'
%
%   'TargetMorale'   : 'sparkle', 'normal', 'orange', 'red'
%                       Default: 'normal'
%
%   'Formation'      : Attacker formation
%                       'line_ahead'      -> 1.00
%                       'double_line'     -> 0.80
%                       'diamond'         -> 0.70
%                       'echelon'         -> 0.60
%                       'vanguard'        -> 0.50
%                       'line_abreast'    -> 0.90
%                       Default: 'line_ahead'
%
%   'TargetFormation' : Enemy formation.
%                        'line_ahead', 'double_line', 'diamond',
%                        'echelon', 'vanguard', 'line_abreast'
%                        Default: 'line_ahead'
%
%   'TargetPosition' : Enemy position in the fleet, 1--7.
%                      Relevant only for vanguard/警戒陣.
%                      Default: 1
%
%   'TargetIsDestroyer' : true/false
%                         Relevant only for vanguard/警戒陣.
%                         Default: false
%
%   'EventNode' : true/false
%                Determines the special destroyer 警戒陣 modifier.
%                Default: false
%
%   Output
%   ------
%   result is a structure containing:
%       .basicAccuracyTerm
%       .vanguardModifier
%       .accuracyTerm
%       .basicEvasionTerm
%       .evasionTerm
%       .accuracyMinusEvasion
%       .cappedTerm
%       .hitPercent
%       .criticalPercent
%       .normalHitPercent
%       .missPercent
%
%   The implementation follows Fleethub's support shelling calculation.

%% Parse options

p = inputParser;

addParameter(p, 'AttackerMorale', 'normal');
addParameter(p, 'TargetMorale', 'normal');
addParameter(p, 'Formation', 'line_ahead');
addParameter(p, 'TargetFormation', 'line_ahead');
addParameter(p, 'TargetPosition', 1);
addParameter(p, 'TargetIsDestroyer', false);
addParameter(p, 'EventNode', false);

parse(p, varargin{:});

attackerMorale = lower(p.Results.AttackerMorale);
targetMorale   = lower(p.Results.TargetMorale);
formation      = lower(p.Results.Formation);
targetFormation = lower(p.Results.TargetFormation);

targetPosition = p.Results.TargetPosition;
targetIsDestroyer = p.Results.TargetIsDestroyer;
eventNode = p.Results.EventNode;

%% ============================================================
% 1. Attacker accuracy term
% =============================================================

% FleetHub:
%
% basic_accuracy_term =
%       2*sqrt(level) + 1.5*sqrt(luck)
%
% accuracy term before morale/formation:
%
% floor(64 + basic_accuracy_term + equipment accuracy)

basicAccuracy = ...
    2.0 * sqrt(attackerLevel) + ...
    1.5 * sqrt(attackerLuck);

accuracyTerm = floor(64.0 + basicAccuracy + attackerAcc);

%% ============================================================
% 2. Enemy formation / Vanguard modifier
% =============================================================

vanguardMod = 1.0;

if strcmp(targetFormation, 'vanguard')

    if targetIsDestroyer

        if eventNode
            % Event-node 警戒陣
            switch targetPosition
                case {1, 2}
                    vanguardMod = 0.95;
                case {3, 4}
                    vanguardMod = 0.66;
                case 5
                    vanguardMod = 0.52;
                case 6
                    vanguardMod = 0.48;
                case 7
                    vanguardMod = 0.40;
                otherwise
                    error('TargetPosition must be 1--7.');
            end

        else
            % Normal-node 警戒陣
            switch targetPosition
                case {1, 2}
                    vanguardMod = 0.95;
                case {3, 4}
                    vanguardMod = 0.80;
                case 5
                    vanguardMod = 0.69;
                case {6, 7}
                    vanguardMod = 0.64;
                otherwise
                    error('TargetPosition must be 1--7.');
            end
        end

    else
        % Non-destroyer 警戒陣
        switch targetPosition
            case {1, 2, 3, 4}
                vanguardMod = 0.95;
            case 5
                vanguardMod = 0.86;
            case 6
                vanguardMod = 0.80;
            case 7
                vanguardMod = 0.70;
            otherwise
                error('TargetPosition must be 1--7.');
        end
    end
end

% FleetHub explicitly floors here:
%
% multiplicand =
%     floor(64 + basic accuracy + equipment accuracy)
%     * vanguard modifier
%
% then floor again.

accuracyTerm = floor(accuracyTerm * vanguardMod);

%% ============================================================
% 3. Attacker formation accuracy modifier
% =============================================================

formationAccuracyMod = getFormationAccuracyModifier(formation);

%% ============================================================
% 4. Attacker morale accuracy modifier
% =============================================================

attackerMoraleMod = getAttackerMoraleAccuracyModifier(attackerMorale);

% FleetHub:
%
% accuracy_term =
% floor(multiplicand * formation_mod * morale_mod)

accuracyTerm = floor( ...
    accuracyTerm * ...
    formationAccuracyMod * ...
    attackerMoraleMod);

%% ============================================================
% 5. Enemy basic evasion term
% =============================================================

% FleetHub:
%
% basic_evasion_term =
%       evasion + sqrt(2 * luck)

basicEvasion = enemyEvasion + sqrt(2.0 * enemyLuck);

%% ============================================================
% 6. Enemy formation evasion modifier
% =============================================================

targetEvasionFormationMod = ...
    getFormationEvasionModifier(targetFormation);

%% ============================================================
% 7. Enemy evasion pre-cap
% =============================================================

% FleetHub first calculates:
%
% base = floor(basic_evasion_term * formation_mod)

baseEvasion = floor( ...
    basicEvasion * targetEvasionFormationMod);

%% ============================================================
% 8. Enemy evasion soft cap
% =============================================================

if baseEvasion >= 65

    postcapEvasion = floor( ...
        55 + 2 * sqrt(baseEvasion - 65));

elseif baseEvasion >= 40

    postcapEvasion = floor( ...
        40 + 3 * sqrt(baseEvasion - 40));

else

    postcapEvasion = baseEvasion;

end

%% ============================================================
% 9. Final enemy evasion term
% =============================================================

% Support shelling passes:
%
% postcap_additive       = 0
% postcap_multiplicative = 1
%
% and therefore:
%
% evasion_term = floor(postcapEvasion) 
%
% minus remaining fuel modifier.
%
% We assume full fuel here, so fuel modifier = 0.

evasionTerm = floor(postcapEvasion);

%% ============================================================
% 10. Target morale modifier
% =============================================================

targetMoraleMod = getTargetMoraleHitModifier(targetMorale);

%% ============================================================
% 11. Hit-rate calculation
% =============================================================

% FleetHub:
%
% v = max(accuracyTerm - evasionTerm, 10)
%
% capped = min(v * targetMoraleMod, 96)

v = max(accuracyTerm - evasionTerm, 10);

cappedTerm = min(v * targetMoraleMod, 96);

% Support shelling:
%
% hit_percentage_bonus      = 0
% critical_percentage_bonus = 0
% critical_rate_constant    = 1

hitPercent = floor(cappedTerm + 1);

criticalPercent = floor(sqrt(cappedTerm) + 1);

% The total hit probability cannot exceed 100%.
hitPercent = min(hitPercent, 100);
criticalPercent = min(criticalPercent, 100);

normalHitPercent = max(hitPercent - criticalPercent, 0);

missPercent = max(100 - hitPercent, 0);

%% ============================================================
% Output
% =============================================================

result = struct();

result.basicAccuracyTerm = basicAccuracy;
result.vanguardModifier = vanguardMod;

result.accuracyTerm = accuracyTerm;

result.basicEvasionTerm = basicEvasion;
result.baseEvasion = baseEvasion;
result.postcapEvasion = postcapEvasion;
result.evasionTerm = evasionTerm;

result.accuracyMinusEvasion = accuracyTerm - evasionTerm;

result.targetMoraleModifier = targetMoraleMod;
result.cappedTerm = cappedTerm;

result.hitPercent = hitPercent;
result.criticalPercent = criticalPercent;
result.normalHitPercent = normalHitPercent;
result.missPercent = missPercent;

result.hitProbability = hitPercent / 100;
result.criticalProbability = criticalPercent / 100;
result.normalHitProbability = normalHitPercent / 100;
result.missProbability = missPercent / 100;

end


%% ========================================================================
% Formation accuracy modifiers
% ========================================================================

function mod = getFormationAccuracyModifier(formation)

switch lower(formation)

    case 'line_ahead'
        mod = 1.00;

    case 'double_line'
        mod = 0.80;

    case 'diamond'
        mod = 0.70;

    case 'echelon'
        mod = 0.60;

    case 'vanguard'
        mod = 0.50;

    case 'line_abreast'
        mod = 0.90;

    otherwise
        error('Unknown formation: %s', formation);

end

end


%% ========================================================================
% Formation evasion modifiers
% ========================================================================

function mod = getFormationEvasionModifier(formation)

switch lower(formation)

    case 'line_ahead'
        mod = 1.00;

    case 'double_line'
        mod = 1.20;

    case 'diamond'
        mod = 1.30;

    case 'echelon'
        mod = 1.20;

    case 'vanguard'
        mod = 1.00;

    case 'line_abreast'
        mod = 1.00;

    otherwise
        error('Unknown target formation: %s', formation);

end

end


%% ========================================================================
% Attacker morale accuracy modifier
% ========================================================================

function mod = getAttackerMoraleAccuracyModifier(morale)

switch lower(morale)

    case 'sparkle'
        mod = 1.20;

    case 'normal'
        mod = 1.00;

    case 'orange'
        mod = 0.80;

    case 'red'
        mod = 0.50;

    otherwise
        error('Unknown attacker morale: %s', morale);

end

end


%% ========================================================================
% Target morale modifier
% ========================================================================

function mod = getTargetMoraleHitModifier(morale)

switch lower(morale)

    case 'sparkle'
        mod = 0.70;

    case 'normal'
        mod = 1.00;

    case 'orange'
        mod = 1.20;

    case 'red'
        mod = 1.40;

    otherwise
        error('Unknown target morale: %s', morale);

end

end