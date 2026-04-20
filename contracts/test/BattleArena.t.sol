// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AdventurerNFT} from "../src/AdventurerNFT.sol";
import {BattleArena} from "../src/BattleArena.sol";
import {MockUSDC} from "./MockUSDC.sol";

contract BattleArenaTest is Test {
    AdventurerNFT nft;
    BattleArena arena;
    MockUSDC usdc;
    address treasury = address(0xBEEF);
    address operator = address(this);

    uint256 constant N_PLAYERS = 32;
    address[] players;
    uint256[] tokenIds;

    function setUp() public {
        usdc = new MockUSDC();
        nft = new AdventurerNFT(address(usdc), treasury, address(this));
        arena = new BattleArena(address(usdc), address(nft), address(this));
        nft.setArena(address(arena));
        nft.setPaymentsEnabled(true);

        // Fund operator with USDC for base pool + kill bonuses
        usdc.mint(operator, 10_000e6);
        usdc.approve(address(arena), type(uint256).max);

        // Mint 32 tokens across 32 distinct addresses
        for (uint256 i = 0; i < N_PLAYERS; i++) {
            address p = address(uint160(0x1000 + i));
            players.push(p);
            usdc.mint(p, 100e6);
            vm.prank(p);
            usdc.approve(address(nft), type(uint256).max);
            vm.prevrandao(keccak256(abi.encode("mint", i)));
            vm.prank(p);
            uint256 id = nft.mint();
            tokenIds.push(id);
        }
    }

    function _createAndRegisterAll() internal returns (uint256 matchId, bytes32 seed) {
        seed = keccak256("sample-seed");
        bytes32 seedHash = keccak256(abi.encodePacked(seed));
        matchId = arena.createMatch(seedHash, 50e6);
        for (uint256 i = 0; i < N_PLAYERS; i++) {
            vm.prank(players[i]);
            arena.register(matchId, tokenIds[i]);
        }
    }

    function test_createMatch_transfersBasePool() public {
        bytes32 seed = keccak256("x");
        bytes32 seedHash = keccak256(abi.encodePacked(seed));
        uint256 balBefore = usdc.balanceOf(address(arena));
        arena.createMatch(seedHash, 50e6);
        assertEq(usdc.balanceOf(address(arena)) - balBefore, 50e6);
    }

    function test_register_storesEntrant() public {
        (uint256 matchId, ) = _createAndRegisterAll();
        assertEq(arena.entrantCount(matchId), N_PLAYERS);
        assertTrue(arena.registered(matchId, tokenIds[0]));
        assertEq(arena.registrantOf(matchId, tokenIds[0]), players[0]);
    }

    function test_register_rejectsDuplicates() public {
        bytes32 seed = keccak256("x");
        bytes32 seedHash = keccak256(abi.encodePacked(seed));
        uint256 matchId = arena.createMatch(seedHash, 0);
        vm.prank(players[0]);
        arena.register(matchId, tokenIds[0]);
        vm.prank(players[0]);
        vm.expectRevert(bytes("registered"));
        arena.register(matchId, tokenIds[0]);
    }

    function test_register_rejectsWhenFull() public {
        bytes32 seed = keccak256("x");
        bytes32 seedHash = keccak256(abi.encodePacked(seed));
        uint256 matchId = arena.createMatch(seedHash, 0);
        for (uint256 i = 0; i < 32; i++) {
            vm.prank(players[i]);
            arena.register(matchId, tokenIds[i]);
        }
        // Mint 33rd token
        address extra = address(0xDEAD1);
        usdc.mint(extra, 100e6);
        vm.prank(extra);
        usdc.approve(address(nft), type(uint256).max);
        vm.prank(extra);
        uint256 extraId = nft.mint();
        vm.prank(extra);
        vm.expectRevert(bytes("full"));
        arena.register(matchId, extraId);
    }

    function test_cancel_refundsBase() public {
        bytes32 seed = keccak256("x");
        bytes32 seedHash = keccak256(abi.encodePacked(seed));
        uint256 matchId = arena.createMatch(seedHash, 50e6);
        uint256 balBefore = usdc.balanceOf(operator);
        arena.cancelMatch(matchId);
        assertEq(usdc.balanceOf(operator), balBefore + 50e6);
    }

    function test_cancel_rejectsWhenEnough() public {
        (uint256 matchId, ) = _createAndRegisterAll();
        vm.expectRevert(bytes("enough entrants"));
        arena.cancelMatch(matchId);
    }

    function test_settle_distributesPrize() public {
        (uint256 matchId, bytes32 seed) = _createAndRegisterAll();

        // Construct settlement: champion = first token, rest 31 are slain
        BattleArena.Settlement memory s;
        s.championId = tokenIds[0];
        s.runnerUpId = tokenIds[1];
        s.fourthPlace = [tokenIds[2], tokenIds[3]];
        s.eighthPlace = [tokenIds[4], tokenIds[5], tokenIds[6], tokenIds[7]];

        // Slain = everyone except champion
        s.slainIds = new uint256[](N_PLAYERS - 1);
        for (uint256 i = 0; i < N_PLAYERS - 1; i++) {
            s.slainIds[i] = tokenIds[i + 1];
        }

        // Champion gets all 31 kills (for simplicity in test)
        s.killerIds = new uint256[](1);
        s.killerIds[0] = tokenIds[0];
        s.killCounts = new uint256[](1);
        s.killCounts[0] = 31;
        s.restedIds = new uint256[](0);

        uint256 totalKills = 31;
        uint256 killFund = totalKills * 5e6;

        // Expected pool: basePool (50) + 31 slain × 3 vault × 90% = 50 + 31 × 2.7 = 50 + 83.7 = 133.7 USDC
        uint256 expectedVaultInflow = (N_PLAYERS - 1) * ((3e6 * 90) / 100);
        uint256 expectedPool = 50e6 + expectedVaultInflow;

        uint256 champBefore = usdc.balanceOf(players[0]);
        uint256 runnerBefore = usdc.balanceOf(players[1]);
        uint256 fourthBefore = usdc.balanceOf(players[2]);
        uint256 eighthBefore = usdc.balanceOf(players[4]);

        arena.settle(matchId, seed, s, killFund);

        // Champion gets 50% prize + all kill bonuses
        assertEq(usdc.balanceOf(players[0]), champBefore + (expectedPool * 50) / 100 + totalKills * 5e6, "champ");
        assertEq(usdc.balanceOf(players[1]), runnerBefore + (expectedPool * 20) / 100, "runnerUp");
        assertEq(usdc.balanceOf(players[2]), fourthBefore + (expectedPool * 10) / 100, "fourth");
        assertEq(usdc.balanceOf(players[4]), eighthBefore + (expectedPool * 25) / 1000, "eighth");
        assertFalse(nft.isAlive(tokenIds[1]));
        assertTrue(nft.isAlive(tokenIds[0]));
    }

    function test_settle_rejectsBadSeed() public {
        (uint256 matchId, ) = _createAndRegisterAll();
        BattleArena.Settlement memory s;
        s.championId = tokenIds[0];
        s.runnerUpId = tokenIds[1];
        s.fourthPlace = [tokenIds[2], tokenIds[3]];
        s.eighthPlace = [tokenIds[4], tokenIds[5], tokenIds[6], tokenIds[7]];
        s.slainIds = new uint256[](0);
        s.killerIds = new uint256[](0);
        s.killCounts = new uint256[](0);
        s.restedIds = new uint256[](0);
        vm.expectRevert(bytes("bad seed"));
        arena.settle(matchId, keccak256("wrong"), s, 0);
    }

    function test_settle_rejectsTooFew() public {
        bytes32 seed = keccak256("x");
        bytes32 seedHash = keccak256(abi.encodePacked(seed));
        uint256 matchId = arena.createMatch(seedHash, 50e6);
        // only 10 entrants
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(players[i]);
            arena.register(matchId, tokenIds[i]);
        }
        BattleArena.Settlement memory s;
        s.championId = tokenIds[0];
        s.runnerUpId = tokenIds[1];
        s.fourthPlace = [tokenIds[2], tokenIds[3]];
        s.eighthPlace = [tokenIds[4], tokenIds[5], tokenIds[6], tokenIds[7]];
        s.slainIds = new uint256[](0);
        s.killerIds = new uint256[](0);
        s.killCounts = new uint256[](0);
        s.restedIds = new uint256[](0);
        vm.expectRevert(bytes("too few"));
        arena.settle(matchId, seed, s, 0);
    }

    function test_settle_incrementsRestForNonRegistered() public {
        // Only register 16 (minimum), the other 16 rest
        bytes32 seed = keccak256("r");
        bytes32 seedHash = keccak256(abi.encodePacked(seed));
        uint256 matchId = arena.createMatch(seedHash, 50e6);
        for (uint256 i = 0; i < 16; i++) {
            vm.prank(players[i]);
            arena.register(matchId, tokenIds[i]);
        }

        BattleArena.Settlement memory s;
        s.championId = tokenIds[0];
        s.runnerUpId = tokenIds[1];
        s.fourthPlace = [tokenIds[2], tokenIds[3]];
        s.eighthPlace = [tokenIds[4], tokenIds[5], tokenIds[6], tokenIds[7]];
        s.slainIds = new uint256[](15);
        for (uint256 i = 0; i < 15; i++) s.slainIds[i] = tokenIds[i + 1];
        s.killerIds = new uint256[](0);
        s.killCounts = new uint256[](0);
        // Rest the other 16 tokens
        s.restedIds = new uint256[](16);
        for (uint256 i = 0; i < 16; i++) s.restedIds[i] = tokenIds[16 + i];

        arena.settle(matchId, seed, s, 0);

        // Check that rested tokens have restStreak=1
        (,,,,,,, uint8 restStreak,,,) = nft.statsOf(tokenIds[16]);
        assertEq(restStreak, 1);
    }
}
