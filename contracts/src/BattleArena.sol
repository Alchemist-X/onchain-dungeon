// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IAdventurerNFT {
    function ownerOf(uint256) external view returns (address);
    function isAlive(uint256) external view returns (bool);
    function slay(uint256 tokenId) external returns (uint256 toArena);
    function markParticipated(uint256 tokenId) external;
    function markRested(uint256 tokenId) external returns (bool swallowed);
}

/// @title Battle Arena
/// @notice Hybrid on-chain arena. The operator runs the battle off-chain using
///         a committed seed (mixed with prevrandao + blockhash), then posts
///         settlement on-chain. The contract verifies the seed, slays losers,
///         distributes the prize pool (50/20/10×2/2.5×4) and pays kill bonuses.
contract BattleArena is Ownable {
    using SafeERC20 for IERC20;

    uint256 public constant KILL_BONUS = 5e6;          // 5 USDC per kill
    uint256 public constant DEFAULT_BASE_POOL = 50e6;  // 50 USDC default
    uint256 public constant MAX_ENTRANTS = 32;
    uint256 public constant MIN_ENTRANTS = 16;

    IERC20 public immutable usdc;
    IAdventurerNFT public immutable nft;
    address public operator;

    struct MatchCore {
        bytes32 seedHash;
        bytes32 seed;
        uint256 basePool;
        uint64 createdAt;
        bool settled;
        bool cancelled;
    }

    struct Settlement {
        uint256 championId;
        uint256 runnerUpId;
        uint256[2] fourthPlace;
        uint256[4] eighthPlace;
        uint256[] slainIds;    // every registered token except the champion
        uint256[] killerIds;   // parallel with killCounts
        uint256[] killCounts;
        uint256[] restedIds;   // alive tokens that did not register
    }

    uint256 public nextMatchId = 1;
    mapping(uint256 => MatchCore) public matches;
    mapping(uint256 => uint256[]) private _entrants;
    mapping(uint256 => mapping(uint256 => bool)) public registered;
    mapping(uint256 => mapping(uint256 => address)) public registrantOf;

    event OperatorSet(address indexed operator);
    event MatchCreated(uint256 indexed matchId, bytes32 seedHash, uint256 basePool);
    event Registered(uint256 indexed matchId, uint256 indexed tokenId, address indexed owner);
    event MatchCancelled(uint256 indexed matchId, string reason);
    event MatchSettled(uint256 indexed matchId, uint256 championId, uint256 prizePool);
    event PrizePaid(uint256 indexed matchId, uint256 indexed tokenId, address indexed to, uint256 amount, string placement);
    event KillBonusPaid(uint256 indexed matchId, uint256 indexed tokenId, address indexed to, uint256 amount);

    modifier onlyOperator() {
        require(msg.sender == operator, "not operator");
        _;
    }

    constructor(address usdc_, address nft_, address owner_) Ownable(owner_) {
        require(usdc_ != address(0) && nft_ != address(0) && owner_ != address(0), "zero");
        usdc = IERC20(usdc_);
        nft = IAdventurerNFT(nft_);
        operator = owner_;
    }

    function setOperator(address op) external onlyOwner {
        operator = op;
        emit OperatorSet(op);
    }

    /// @notice Operator creates a match and funds the base prize pool.
    function createMatch(bytes32 seedHash, uint256 basePool) external onlyOperator returns (uint256 matchId) {
        require(seedHash != bytes32(0), "bad seed hash");
        matchId = nextMatchId++;
        matches[matchId] = MatchCore({
            seedHash: seedHash,
            seed: bytes32(0),
            basePool: basePool,
            createdAt: uint64(block.timestamp),
            settled: false,
            cancelled: false
        });
        if (basePool > 0) usdc.safeTransferFrom(msg.sender, address(this), basePool);
        emit MatchCreated(matchId, seedHash, basePool);
    }

    /// @notice Player opts a tokenId into a match. Token must be alive and not already registered.
    function register(uint256 matchId, uint256 tokenId) external {
        MatchCore storage m = matches[matchId];
        require(!m.settled && !m.cancelled, "not open");
        require(m.createdAt != 0, "no match");
        require(nft.ownerOf(tokenId) == msg.sender, "not owner");
        require(nft.isAlive(tokenId), "dead");
        require(!registered[matchId][tokenId], "registered");
        require(_entrants[matchId].length < MAX_ENTRANTS, "full");
        registered[matchId][tokenId] = true;
        registrantOf[matchId][tokenId] = msg.sender;
        _entrants[matchId].push(tokenId);
        emit Registered(matchId, tokenId, msg.sender);
    }

    /// @notice Cancel a match if too few entrants. Base pool returned to operator.
    function cancelMatch(uint256 matchId) external onlyOperator {
        MatchCore storage m = matches[matchId];
        require(!m.settled && !m.cancelled, "not open");
        require(_entrants[matchId].length < MIN_ENTRANTS, "enough entrants");
        m.cancelled = true;
        if (m.basePool > 0) usdc.safeTransfer(msg.sender, m.basePool);
        emit MatchCancelled(matchId, "too few entrants");
    }

    /// @notice Operator settles the match. Reveals seed, slays losers, distributes prize & kill bonuses.
    /// @dev The caller must first fund kill bonuses via USDC approval. killBonusFunded must cover
    ///      sum(killCounts) * KILL_BONUS.
    function settle(uint256 matchId, bytes32 seed, Settlement calldata s, uint256 killBonusFunded) external onlyOperator {
        MatchCore storage m = matches[matchId];
        require(!m.settled && !m.cancelled, "not open");
        require(keccak256(abi.encodePacked(seed)) == m.seedHash, "bad seed");
        require(_entrants[matchId].length >= MIN_ENTRANTS, "too few");
        require(s.killerIds.length == s.killCounts.length, "len mismatch");

        m.seed = seed;
        m.settled = true;

        _incrementRests(s.restedIds);
        uint256 pool = m.basePool + _slayLosers(matchId, s.slainIds);
        nft.markParticipated(s.championId);

        _distributePrizes(matchId, s, pool);
        _distributeKillBonuses(matchId, s, killBonusFunded);

        emit MatchSettled(matchId, s.championId, pool);
    }

    function _incrementRests(uint256[] calldata restedIds) internal {
        for (uint256 i = 0; i < restedIds.length; i++) {
            nft.markRested(restedIds[i]);
        }
    }

    function _slayLosers(uint256 matchId, uint256[] calldata slainIds) internal returns (uint256 collected) {
        for (uint256 i = 0; i < slainIds.length; i++) {
            uint256 id = slainIds[i];
            require(registered[matchId][id], "slain !registered");
            collected += nft.slay(id);
        }
    }

    function _distributePrizes(uint256 matchId, Settlement calldata s, uint256 pool) internal {
        _payPrize(matchId, s.championId, (pool * 50) / 100, "champion");
        _payPrize(matchId, s.runnerUpId, (pool * 20) / 100, "runnerUp");
        for (uint256 i = 0; i < 2; i++) {
            _payPrize(matchId, s.fourthPlace[i], (pool * 10) / 100, "fourth");
        }
        for (uint256 i = 0; i < 4; i++) {
            _payPrize(matchId, s.eighthPlace[i], (pool * 25) / 1000, "eighth");
        }
    }

    function _payPrize(uint256 matchId, uint256 tokenId, uint256 amount, string memory placement) internal {
        if (tokenId == 0 || amount == 0) return;
        address to = registrantOf[matchId][tokenId];
        require(to != address(0), "no registrant");
        usdc.safeTransfer(to, amount);
        emit PrizePaid(matchId, tokenId, to, amount, placement);
    }

    function _distributeKillBonuses(uint256 matchId, Settlement calldata s, uint256 killBonusFunded) internal {
        if (s.killerIds.length == 0) return;
        uint256 totalKills;
        for (uint256 i = 0; i < s.killCounts.length; i++) {
            totalKills += s.killCounts[i];
        }
        uint256 required = totalKills * KILL_BONUS;
        require(killBonusFunded >= required, "underfunded kills");
        if (killBonusFunded > 0) {
            usdc.safeTransferFrom(msg.sender, address(this), killBonusFunded);
        }
        for (uint256 i = 0; i < s.killerIds.length; i++) {
            uint256 amount = s.killCounts[i] * KILL_BONUS;
            if (amount == 0) continue;
            address to = registrantOf[matchId][s.killerIds[i]];
            require(to != address(0), "no registrant");
            usdc.safeTransfer(to, amount);
            emit KillBonusPaid(matchId, s.killerIds[i], to, amount);
        }
        if (killBonusFunded > required) {
            usdc.safeTransfer(msg.sender, killBonusFunded - required);
        }
    }

    // --- Views ---

    function entrants(uint256 matchId) external view returns (uint256[] memory) {
        return _entrants[matchId];
    }

    function entrantCount(uint256 matchId) external view returns (uint256) {
        return _entrants[matchId].length;
    }
}
