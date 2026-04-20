// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title Abyssal Adventurer NFT
/// @notice ERC721 + embedded Vault. Each token is a playable adventurer with
///         rolled stats, stored USDC value, and rest tracking. The Arena
///         contract is authorized to slay / rest-increment tokens.
contract AdventurerNFT is ERC721, Ownable {
    using SafeERC20 for IERC20;

    // --- Economics (USDC, 6 decimals) ---
    uint256 public constant MINT_COST = 5e6;
    uint256 public constant ENHANCE_COST = 2e6;
    uint256 public constant MINT_TO_VAULT = 3e6;
    uint256 public constant MINT_TO_PLATFORM = 2e6;

    // --- Rules ---
    uint8 public constant MAX_ENHANCEMENTS = 10;
    uint8 public constant MAX_STAT_ENHANCEMENT = 5;
    uint8 public constant REST_LIMIT = 7;

    enum Rarity { Common, Uncommon, Rare, Epic, Legendary }
    enum PromptPreset { Balanced, Aggressive, Survival }

    struct Stats {
        uint8 str;
        uint8 agi;
        uint8 luc;
        uint8 enhStr;
        uint8 enhAgi;
        uint8 enhLuc;
        uint8 enhCount;
        uint8 restStreak;
        Rarity rarity;
        PromptPreset preset;
        bool alive;
    }

    IERC20 public immutable usdc;
    address public platformTreasury;
    address public arena;
    uint256 public nextTokenId = 1;
    uint256 public totalBurned;
    uint256 public totalDestroyed; // USDC destroyed (10% burn-share)
    bool public paymentsEnabled;   // when false: mint/enhance are free, vaultOf stays 0

    mapping(uint256 => Stats) public statsOf;
    mapping(uint256 => uint256) public vaultOf;

    event Minted(uint256 indexed id, address indexed owner, Rarity rarity, uint8 str, uint8 agi, uint8 luc);
    event Enhanced(uint256 indexed id, uint8 stat, uint8 newValue, uint256 newVault);
    event Retired(uint256 indexed id, address indexed owner, uint256 refund, uint256 destroyed);
    event Slain(uint256 indexed id, uint256 toArena, uint256 destroyed);
    event Swallowed(uint256 indexed id, uint256 destroyed);
    event PresetSet(uint256 indexed id, PromptPreset preset);
    event PlatformTreasurySet(address indexed treasury);
    event ArenaSet(address indexed arena);
    event PaymentsEnabled(bool enabled);

    modifier onlyArena() {
        require(msg.sender == arena, "not arena");
        _;
    }

    constructor(address usdc_, address platformTreasury_, address owner_)
        ERC721("Abyssal Adventurer", "ADV")
        Ownable(owner_)
    {
        require(usdc_ != address(0) && platformTreasury_ != address(0) && owner_ != address(0), "zero addr");
        usdc = IERC20(usdc_);
        platformTreasury = platformTreasury_;
    }

    // --- Admin ---

    function setPlatformTreasury(address t) external onlyOwner {
        require(t != address(0), "zero");
        platformTreasury = t;
        emit PlatformTreasurySet(t);
    }

    function setArena(address a) external onlyOwner {
        arena = a;
        emit ArenaSet(a);
    }

    function setPaymentsEnabled(bool enabled) external onlyOwner {
        paymentsEnabled = enabled;
        emit PaymentsEnabled(enabled);
    }

    // --- Player actions ---

    function mint() external returns (uint256 tokenId) {
        tokenId = nextTokenId++;
        if (paymentsEnabled) {
            usdc.safeTransferFrom(msg.sender, address(this), MINT_COST);
            usdc.safeTransfer(platformTreasury, MINT_TO_PLATFORM);
            vaultOf[tokenId] = MINT_TO_VAULT;
        }

        Rarity r = _rollRarity(tokenId);
        (uint8 s, uint8 a, uint8 l) = _rollStats(tokenId, r);
        statsOf[tokenId] = Stats({
            str: s, agi: a, luc: l,
            enhStr: 0, enhAgi: 0, enhLuc: 0,
            enhCount: 0, restStreak: 0,
            rarity: r, preset: PromptPreset.Balanced, alive: true
        });
        _safeMint(msg.sender, tokenId);
        emit Minted(tokenId, msg.sender, r, s, a, l);
    }

    /// @param statIdx 0=STR, 1=AGI, 2=LUC
    function enhance(uint256 tokenId, uint8 statIdx) external {
        require(ownerOf(tokenId) == msg.sender, "not owner");
        Stats storage st = statsOf[tokenId];
        require(st.alive, "not alive");
        require(st.enhCount < MAX_ENHANCEMENTS, "max enh");
        require(statIdx < 3, "bad stat");

        uint8 newVal;
        if (statIdx == 0) {
            require(st.enhStr < MAX_STAT_ENHANCEMENT, "stat capped");
            st.str += 1; st.enhStr += 1; newVal = st.str;
        } else if (statIdx == 1) {
            require(st.enhAgi < MAX_STAT_ENHANCEMENT, "stat capped");
            st.agi += 1; st.enhAgi += 1; newVal = st.agi;
        } else {
            require(st.enhLuc < MAX_STAT_ENHANCEMENT, "stat capped");
            st.luc += 1; st.enhLuc += 1; newVal = st.luc;
        }
        st.enhCount += 1;

        if (paymentsEnabled) {
            usdc.safeTransferFrom(msg.sender, address(this), ENHANCE_COST);
            vaultOf[tokenId] += ENHANCE_COST;
        }
        emit Enhanced(tokenId, statIdx, newVal, vaultOf[tokenId]);
    }

    function setPreset(uint256 tokenId, PromptPreset preset) external {
        require(ownerOf(tokenId) == msg.sender, "not owner");
        require(statsOf[tokenId].alive, "not alive");
        statsOf[tokenId].preset = preset;
        emit PresetSet(tokenId, preset);
    }

    function retire(uint256 tokenId) external {
        require(ownerOf(tokenId) == msg.sender, "not owner");
        Stats storage st = statsOf[tokenId];
        require(st.alive, "not alive");
        uint256 vault = vaultOf[tokenId];
        uint256 refund = (vault * 90) / 100;
        uint256 destroyed = vault - refund;
        vaultOf[tokenId] = 0;
        totalDestroyed += destroyed;
        st.alive = false;
        _burn(tokenId);
        totalBurned += 1;
        if (refund > 0) usdc.safeTransfer(msg.sender, refund);
        emit Retired(tokenId, msg.sender, refund, destroyed);
    }

    // --- Arena hooks ---

    /// @notice Arena kills a token and receives 90% of its vault. 10% is destroyed.
    function slay(uint256 tokenId) external onlyArena returns (uint256 toArena) {
        Stats storage st = statsOf[tokenId];
        require(st.alive, "not alive");
        uint256 vault = vaultOf[tokenId];
        vaultOf[tokenId] = 0;
        st.alive = false;
        _burn(tokenId);
        totalBurned += 1;

        toArena = (vault * 90) / 100;
        uint256 destroyed = vault - toArena;
        totalDestroyed += destroyed;
        if (toArena > 0) usdc.safeTransfer(arena, toArena);
        emit Slain(tokenId, toArena, destroyed);
    }

    function markParticipated(uint256 tokenId) external onlyArena {
        statsOf[tokenId].restStreak = 0;
    }

    /// @notice Increment rest streak; if it hits REST_LIMIT, swallow (burn) and destroy full vault.
    function markRested(uint256 tokenId) external onlyArena returns (bool swallowed) {
        Stats storage st = statsOf[tokenId];
        require(st.alive, "not alive");
        st.restStreak += 1;
        if (st.restStreak >= REST_LIMIT) {
            uint256 vault = vaultOf[tokenId];
            vaultOf[tokenId] = 0;
            totalDestroyed += vault;
            st.alive = false;
            _burn(tokenId);
            totalBurned += 1;
            emit Swallowed(tokenId, vault);
            return true;
        }
        return false;
    }

    // --- Views ---

    function hp(uint256 tokenId) external view returns (uint256) {
        return 40 + uint256(statsOf[tokenId].str) * 3;
    }

    function isAlive(uint256 tokenId) external view returns (bool) {
        return statsOf[tokenId].alive;
    }

    // --- Internals: randomness ---

    function _rollRarity(uint256 tokenId) internal view returns (Rarity) {
        uint256 r = uint256(
            keccak256(abi.encode(block.prevrandao, blockhash(block.number - 1), tokenId, msg.sender, "rarity"))
        ) % 100;
        if (r < 60) return Rarity.Common;
        if (r < 85) return Rarity.Uncommon;
        if (r < 95) return Rarity.Rare;
        if (r < 99) return Rarity.Epic;
        return Rarity.Legendary;
    }

    function _rollStats(uint256 tokenId, Rarity r) internal view returns (uint8 s, uint8 a, uint8 l) {
        (uint8 total, uint8 cap) = _rarityParams(r);
        s = 1; a = 1; l = 1;
        uint8 remaining = total - 3;
        uint256 seed = uint256(
            keccak256(abi.encode(block.prevrandao, blockhash(block.number - 1), tokenId, msg.sender, "stats"))
        );
        uint256 guard = 0;
        while (remaining > 0 && guard < 256) {
            uint256 pick = seed % 3;
            seed = uint256(keccak256(abi.encode(seed, remaining)));
            if (pick == 0 && s < cap) { s += 1; remaining -= 1; }
            else if (pick == 1 && a < cap) { a += 1; remaining -= 1; }
            else if (pick == 2 && l < cap) { l += 1; remaining -= 1; }
            guard += 1;
        }
    }

    function _rarityParams(Rarity r) internal pure returns (uint8 total, uint8 cap) {
        if (r == Rarity.Common) return (15, 7);
        if (r == Rarity.Uncommon) return (17, 8);
        if (r == Rarity.Rare) return (19, 9);
        if (r == Rarity.Epic) return (21, 10);
        return (23, 10);
    }
}
