// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IAdventurer {
    function ownerOf(uint256) external view returns (address);
    function isAlive(uint256) external view returns (bool);
    function slay(uint256) external returns (uint256 toArena);
    function statsOf(uint256) external view returns (
        uint8 str, uint8 agi, uint8 luc,
        uint8 enhStr, uint8 enhAgi, uint8 enhLuc,
        uint8 enhCount, uint8 restStreak,
        uint8 rarity, uint8 preset, bool alive
    );
}

/// @title Onchain Arena — Round-Clock Protocol (ORC-v1)
/// @notice Trustless on-chain 32-person tournament. Each living combatant's
///         agent submits one action per 30-second window. After the window,
///         anyone calls resolveRound() which applies actions with on-chain dice.
///         Replaces the operator-settled BattleArena.
contract OnchainArena is Ownable {
    using SafeERC20 for IERC20;

    uint256 public constant ROUND_WINDOW = 30 seconds;
    uint256 public constant KILL_BONUS = 5e6;
    uint256 public constant MAX_ENTRANTS = 32;
    uint256 public constant MIN_ENTRANTS = 16;
    uint256 public constant DEFEND_BONUS = 4;

    IERC20 public immutable usdc;
    IAdventurer public immutable nft;
    address public operator;

    enum Phase { None, Registration, Running, Settled, Cancelled }
    enum Stage { Quarterfinal, Semifinal, Final }
    enum ActionKind { Wait, Attack, Defend }

    struct Action {
        ActionKind kind;
        uint256 target;
    }

    struct MatchCore {
        Phase phase;
        Stage stage;
        bytes32 seedHash;
        bytes32 seed;
        uint64 registrationEnd;
        uint64 currentRoundStart;
        uint32 currentRound;
        uint256 basePool;
        uint256 prizePool;
        uint256 killBudget;
        address creator;
    }

    uint256 public nextMatchId = 1;
    mapping(uint256 => MatchCore) public matches;

    mapping(uint256 => uint256[]) private _entrants;
    mapping(uint256 => mapping(uint256 => bool)) public registered;
    mapping(uint256 => mapping(uint256 => address)) public registrantOf;

    mapping(uint256 => mapping(uint8 => uint256[][])) private _tables;
    mapping(uint256 => mapping(uint256 => uint256)) public tableOf;

    mapping(uint256 => mapping(uint256 => uint256)) public hpOf;
    mapping(uint256 => mapping(uint256 => bool)) public aliveOf;
    mapping(uint256 => mapping(uint256 => uint256)) public killsOf;

    mapping(uint256 => mapping(uint32 => mapping(uint256 => Action))) private _actions;
    mapping(uint256 => mapping(uint32 => mapping(uint256 => bool))) public actedInRound;

    mapping(uint256 => mapping(uint8 => mapping(uint256 => uint256[]))) private _elimOrder;

    event OperatorSet(address indexed op);
    event MatchCreated(uint256 indexed id, bytes32 seedHash, uint256 basePool, uint64 registrationEnd);
    event Registered(uint256 indexed id, uint256 indexed tokenId, address owner);
    event MatchStarted(uint256 indexed id, uint256 entrantCount);
    event StageAdvanced(uint256 indexed id, Stage stage);
    event Acted(uint256 indexed id, uint32 round, uint256 indexed tokenId, ActionKind kind, uint256 target);
    event RoundResolved(uint256 indexed id, uint32 round, uint256 dead);
    event Eliminated(uint256 indexed id, uint256 indexed tokenId, uint256 indexed killer, uint256 damage);
    event MatchSettled(uint256 indexed id, uint256 championId, uint256 prizePool);
    event MatchCancelled(uint256 indexed id);
    event PrizePaid(uint256 indexed id, uint256 indexed tokenId, address to, uint256 amount, string placement);
    event KillBonusPaid(uint256 indexed id, uint256 indexed tokenId, address to, uint256 amount);

    modifier onlyOperator() { require(msg.sender == operator, "not operator"); _; }

    constructor(address usdc_, address nft_, address owner_) Ownable(owner_) {
        require(usdc_ != address(0) && nft_ != address(0) && owner_ != address(0), "zero");
        usdc = IERC20(usdc_);
        nft = IAdventurer(nft_);
        operator = owner_;
    }

    function setOperator(address op) external onlyOwner {
        operator = op;
        emit OperatorSet(op);
    }

    // ----------------- Match lifecycle -----------------

    function createMatch(bytes32 seedHash, uint256 basePool, uint64 registrationEnd)
        external onlyOperator returns (uint256 matchId)
    {
        require(seedHash != bytes32(0), "bad seed");
        require(registrationEnd > block.timestamp, "end in past");
        matchId = nextMatchId++;
        MatchCore storage m = matches[matchId];
        m.phase = Phase.Registration;
        m.seedHash = seedHash;
        m.basePool = basePool;
        m.prizePool = basePool;
        m.registrationEnd = registrationEnd;
        m.creator = msg.sender;
        if (basePool > 0) usdc.safeTransferFrom(msg.sender, address(this), basePool);
        emit MatchCreated(matchId, seedHash, basePool, registrationEnd);
    }

    function register(uint256 matchId, uint256 tokenId) external {
        MatchCore storage m = matches[matchId];
        require(m.phase == Phase.Registration, "not open");
        require(block.timestamp < m.registrationEnd, "too late");
        require(nft.ownerOf(tokenId) == msg.sender, "not owner");
        require(nft.isAlive(tokenId), "dead");
        require(!registered[matchId][tokenId], "already");
        require(_entrants[matchId].length < MAX_ENTRANTS, "full");
        registered[matchId][tokenId] = true;
        registrantOf[matchId][tokenId] = msg.sender;
        _entrants[matchId].push(tokenId);
        emit Registered(matchId, tokenId, msg.sender);
    }

    function cancelMatch(uint256 matchId) external onlyOperator {
        MatchCore storage m = matches[matchId];
        require(m.phase == Phase.Registration, "bad phase");
        require(_entrants[matchId].length < MIN_ENTRANTS, "enough");
        m.phase = Phase.Cancelled;
        if (m.basePool > 0) usdc.safeTransfer(m.creator, m.basePool);
        emit MatchCancelled(matchId);
    }

    /// @notice Anyone can start the match once registration has ended. Reveals seed.
    ///         Caller may also fund the kill bonus budget in the same tx.
    function startMatch(uint256 matchId, bytes32 seed, uint256 killBudget) external {
        MatchCore storage m = matches[matchId];
        require(m.phase == Phase.Registration, "not registration");
        require(block.timestamp >= m.registrationEnd, "registration open");
        require(_entrants[matchId].length >= MIN_ENTRANTS, "too few");
        require(keccak256(abi.encodePacked(seed)) == m.seedHash, "bad seed");

        m.seed = seed;
        m.phase = Phase.Running;
        m.stage = Stage.Quarterfinal;
        m.currentRound = 0;
        m.currentRoundStart = uint64(block.timestamp);

        if (killBudget > 0) {
            usdc.safeTransferFrom(msg.sender, address(this), killBudget);
            m.killBudget = killBudget;
        }

        uint256[] memory entrants = _entrants[matchId];
        for (uint256 i = 0; i < entrants.length; i++) {
            uint256 id = entrants[i];
            aliveOf[matchId][id] = true;
            (uint8 s,,,,,,,,,,) = nft.statsOf(id);
            hpOf[matchId][id] = 40 + uint256(s) * 3;
        }

        _buildTables(matchId, Stage.Quarterfinal, _shuffle(entrants, seed));
        emit MatchStarted(matchId, entrants.length);
    }

    // ----------------- Action submission -----------------

    function act(uint256 matchId, uint256 tokenId, ActionKind kind, uint256 target) external {
        MatchCore storage m = matches[matchId];
        require(m.phase == Phase.Running, "not running");
        require(block.timestamp < m.currentRoundStart + ROUND_WINDOW, "window closed");
        require(nft.ownerOf(tokenId) == msg.sender, "not owner");
        require(aliveOf[matchId][tokenId], "dead");
        require(!actedInRound[matchId][m.currentRound][tokenId], "already acted");

        if (kind == ActionKind.Attack) {
            require(target != tokenId, "no self");
            require(aliveOf[matchId][target], "target dead");
            require(tableOf[matchId][tokenId] == tableOf[matchId][target], "diff table");
        }

        _actions[matchId][m.currentRound][tokenId] = Action(kind, target);
        actedInRound[matchId][m.currentRound][tokenId] = true;
        emit Acted(matchId, m.currentRound, tokenId, kind, target);
    }

    // ----------------- Resolve -----------------

    function resolveRound(uint256 matchId) external {
        MatchCore storage m = matches[matchId];
        require(m.phase == Phase.Running, "not running");
        require(block.timestamp >= m.currentRoundStart + ROUND_WINDOW, "window open");

        uint32 round = m.currentRound;
        uint256 deadCount = _processRound(matchId, round);
        emit RoundResolved(matchId, round, deadCount);

        if (_stageComplete(matchId)) {
            _advanceStage(matchId);
        } else {
            m.currentRound = round + 1;
            m.currentRoundStart = uint64(block.timestamp);
        }
    }

    function _processRound(uint256 matchId, uint32 round) internal returns (uint256 deadCount) {
        MatchCore storage m = matches[matchId];
        uint256[] memory actors = _aliveList(matchId);
        if (actors.length <= 1) return 0;

        // Initiative: AGI + D20, sort desc
        uint256[] memory init = new uint256[](actors.length);
        for (uint256 i = 0; i < actors.length; i++) {
            (, uint8 agi,,,,,,,,,) = nft.statsOf(actors[i]);
            init[i] = uint256(agi) + _roll(matchId, round, actors[i], 0, 20);
        }
        _sortDesc(actors, init);

        for (uint256 i = 0; i < actors.length; i++) {
            uint256 id = actors[i];
            if (!aliveOf[matchId][id]) continue;
            if (!actedInRound[matchId][round][id]) continue;

            Action memory a = _actions[matchId][round][id];
            if (a.kind != ActionKind.Attack) continue;

            uint256 tgt = a.target;
            if (!aliveOf[matchId][tgt]) continue;

            (uint8 sSelf, uint8 aSelf, uint8 lSelf,,,,,,,,) = nft.statsOf(id);
            (, uint8 aTgt,,,,,,,,,) = nft.statsOf(tgt);

            uint256 guard = _isDefending(matchId, round, tgt) ? DEFEND_BONUS : 0;
            uint256 atkRoll = uint256(aSelf) + _roll(matchId, round, id, 1, 20);
            uint256 defRoll = uint256(aTgt) + _roll(matchId, round, tgt, 2, 20) + guard;
            if (atkRoll < defRoll) continue;

            uint256 baseDmg = uint256(sSelf) + _roll(matchId, round, id, 3, 10);
            uint256 crit = uint256(lSelf) + _roll(matchId, round, id, 4, 20);
            uint256 mult = crit >= 28 ? 3 : (crit >= 22 ? 2 : 1);
            uint256 dmg = baseDmg * mult;

            if (dmg >= hpOf[matchId][tgt]) {
                hpOf[matchId][tgt] = 0;
                aliveOf[matchId][tgt] = false;
                killsOf[matchId][id] += 1;
                _elimOrder[matchId][uint8(m.stage)][tableOf[matchId][tgt]].push(tgt);
                uint256 vaultIn = nft.slay(tgt);
                m.prizePool += vaultIn;
                deadCount += 1;
                emit Eliminated(matchId, tgt, id, dmg);
            } else {
                hpOf[matchId][tgt] -= dmg;
            }
        }
    }

    function _isDefending(uint256 matchId, uint32 round, uint256 tokenId) internal view returns (bool) {
        return actedInRound[matchId][round][tokenId] &&
               _actions[matchId][round][tokenId].kind == ActionKind.Defend;
    }

    function _stageComplete(uint256 matchId) internal view returns (bool) {
        MatchCore storage m = matches[matchId];
        uint8 s = uint8(m.stage);
        uint256 tableCount = _tables[matchId][s].length;
        for (uint256 t = 0; t < tableCount; t++) {
            uint256[] storage tbl = _tables[matchId][s][t];
            uint256 aliveIn = 0;
            for (uint256 i = 0; i < tbl.length; i++) {
                if (aliveOf[matchId][tbl[i]]) aliveIn++;
            }
            if (aliveIn > 1) return false;
        }
        return true;
    }

    function _advanceStage(uint256 matchId) internal {
        MatchCore storage m = matches[matchId];
        uint256[] memory advancers = _currentAdvancers(matchId);

        if (m.stage == Stage.Final) {
            _finalize(matchId, advancers.length > 0 ? advancers[0] : 0);
            return;
        }

        Stage next = m.stage == Stage.Quarterfinal ? Stage.Semifinal : Stage.Final;
        m.stage = next;
        m.currentRound = 0;
        m.currentRoundStart = uint64(block.timestamp);
        uint256[] memory shuffled = _shuffle(advancers, keccak256(abi.encode(m.seed, next)));
        _buildTables(matchId, next, shuffled);
        emit StageAdvanced(matchId, next);
    }

    function _currentAdvancers(uint256 matchId) internal view returns (uint256[] memory) {
        MatchCore storage m = matches[matchId];
        uint8 s = uint8(m.stage);
        uint256 n = _tables[matchId][s].length;
        uint256[] memory out = new uint256[](n);
        uint256 idx = 0;
        for (uint256 t = 0; t < n; t++) {
            uint256[] storage tbl = _tables[matchId][s][t];
            for (uint256 i = 0; i < tbl.length; i++) {
                if (aliveOf[matchId][tbl[i]]) { out[idx++] = tbl[i]; break; }
            }
        }
        assembly { mstore(out, idx) }
        return out;
    }

    function _finalize(uint256 matchId, uint256 championId) internal {
        MatchCore storage m = matches[matchId];
        m.phase = Phase.Settled;

        if (championId != 0) {
            _pay(matchId, championId, (m.prizePool * 50) / 100, "champion");
        }

        uint256[] storage finalElims = _elimOrder[matchId][uint8(Stage.Final)][0];
        uint256 runnerUp = finalElims.length > 0 ? finalElims[finalElims.length - 1] : 0;
        if (runnerUp != 0) _pay(matchId, runnerUp, (m.prizePool * 20) / 100, "runnerUp");

        for (uint256 t = 0; t < 2; t++) {
            uint256[] storage elims = _elimOrder[matchId][uint8(Stage.Semifinal)][t];
            uint256 len = elims.length;
            if (len == 0) continue;
            _pay(matchId, elims[len - 1], (m.prizePool * 10) / 100, "fourth");
            for (uint256 i = 0; i + 1 < len; i++) {
                _pay(matchId, elims[i], (m.prizePool * 25) / 1000, "eighth");
            }
        }

        _payKillBonuses(matchId);
        emit MatchSettled(matchId, championId, m.prizePool);
    }

    function _pay(uint256 matchId, uint256 tokenId, uint256 amount, string memory placement) internal {
        if (amount == 0 || tokenId == 0) return;
        address to = registrantOf[matchId][tokenId];
        if (to == address(0)) return;
        usdc.safeTransfer(to, amount);
        emit PrizePaid(matchId, tokenId, to, amount, placement);
    }

    function _payKillBonuses(uint256 matchId) internal {
        MatchCore storage m = matches[matchId];
        uint256 budget = m.killBudget;
        if (budget == 0) return;
        uint256[] storage all = _entrants[matchId];
        for (uint256 i = 0; i < all.length && budget > 0; i++) {
            uint256 id = all[i];
            uint256 kills = killsOf[matchId][id];
            if (kills == 0) continue;
            uint256 amount = kills * KILL_BONUS;
            if (amount > budget) amount = budget;
            address to = registrantOf[matchId][id];
            if (to == address(0)) continue;
            usdc.safeTransfer(to, amount);
            budget -= amount;
            emit KillBonusPaid(matchId, id, to, amount);
        }
        m.killBudget = budget;
    }

    // ----------------- Helpers -----------------

    function _buildTables(uint256 matchId, Stage stage, uint256[] memory combatants) internal {
        uint256 size = stage == Stage.Final ? 2 : 4;
        uint8 s = uint8(stage);
        uint256 n = combatants.length;
        require(n % size == 0, "odd split");
        uint256 tableCount = n / size;
        for (uint256 t = 0; t < tableCount; t++) {
            _tables[matchId][s].push();
            uint256[] storage tbl = _tables[matchId][s][t];
            for (uint256 i = 0; i < size; i++) {
                uint256 id = combatants[t * size + i];
                tbl.push(id);
                tableOf[matchId][id] = t;
            }
        }
    }

    function _aliveList(uint256 matchId) internal view returns (uint256[] memory out) {
        uint256[] storage e = _entrants[matchId];
        uint256 n = e.length;
        uint256 c = 0;
        for (uint256 i = 0; i < n; i++) if (aliveOf[matchId][e[i]]) c++;
        out = new uint256[](c);
        uint256 idx = 0;
        for (uint256 i = 0; i < n; i++) if (aliveOf[matchId][e[i]]) out[idx++] = e[i];
    }

    function _shuffle(uint256[] memory arr, bytes32 seed) internal pure returns (uint256[] memory) {
        uint256 n = arr.length;
        for (uint256 i = n; i > 1; i--) {
            uint256 j = uint256(keccak256(abi.encode(seed, i))) % i;
            (arr[i - 1], arr[j]) = (arr[j], arr[i - 1]);
        }
        return arr;
    }

    function _sortDesc(uint256[] memory ids, uint256[] memory keys) internal pure {
        uint256 n = ids.length;
        for (uint256 i = 1; i < n; i++) {
            uint256 k = keys[i]; uint256 v = ids[i]; uint256 j = i;
            while (j > 0 && keys[j - 1] < k) {
                keys[j] = keys[j - 1]; ids[j] = ids[j - 1]; j--;
            }
            keys[j] = k; ids[j] = v;
        }
    }

    function _roll(uint256 matchId, uint32 round, uint256 actor, uint256 idx, uint256 sides)
        internal view returns (uint256)
    {
        bytes32 entropy = keccak256(
            abi.encode(matches[matchId].seed, matchId, round, actor, idx, block.prevrandao)
        );
        return (uint256(entropy) % sides) + 1;
    }

    // ----------------- Views -----------------

    function entrants(uint256 matchId) external view returns (uint256[] memory) {
        return _entrants[matchId];
    }

    function entrantCount(uint256 matchId) external view returns (uint256) {
        return _entrants[matchId].length;
    }

    function tableOfAt(uint256 matchId, Stage stage, uint256 tableIdx)
        external view returns (uint256[] memory)
    {
        return _tables[matchId][uint8(stage)][tableIdx];
    }

    function tablesAtStage(uint256 matchId, Stage stage) external view returns (uint256) {
        return _tables[matchId][uint8(stage)].length;
    }

    function actionOf(uint256 matchId, uint32 round, uint256 tokenId)
        external view returns (ActionKind kind, uint256 target)
    {
        Action storage a = _actions[matchId][round][tokenId];
        return (a.kind, a.target);
    }
}
