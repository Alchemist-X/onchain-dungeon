// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AdventurerNFT} from "../src/AdventurerNFT.sol";
import {UnchainArena} from "../src/UnchainArena.sol";
import {MockUSDC} from "./MockUSDC.sol";

/// @dev Smoke coverage for URC-v1. Not exhaustive — focus is on the happy path
///      (register, start, act, resolveRound) + access-control reverts.
contract UnchainArenaTest is Test {
    AdventurerNFT nft;
    UnchainArena arena;
    MockUSDC usdc;
    address treasury = address(0xBEEF);
    address operator = address(this);
    uint256 constant N = 16;
    address[N] players;
    uint256[N] tokenIds;

    function setUp() public {
        usdc = new MockUSDC();
        nft = new AdventurerNFT(address(usdc), treasury, address(this));
        arena = new UnchainArena(address(usdc), address(nft), address(this));
        nft.setArena(address(arena));
        nft.setPaymentsEnabled(false);

        usdc.mint(operator, 10_000e6);
        usdc.approve(address(arena), type(uint256).max);

        for (uint256 i = 0; i < N; i++) {
            address p = address(uint160(0x1000 + i));
            players[i] = p;
            vm.prevrandao(keccak256(abi.encode("mint", i)));
            vm.prank(p);
            tokenIds[i] = nft.mint();
        }
    }

    function _openMatch() internal returns (uint256 matchId, bytes32 seed) {
        seed = keccak256("urcv1-seed");
        bytes32 seedHash = keccak256(abi.encodePacked(seed));
        uint64 regEnd = uint64(block.timestamp + 60);
        matchId = arena.createMatch(seedHash, 50e6, regEnd);
        for (uint256 i = 0; i < N; i++) {
            vm.prank(players[i]);
            arena.register(matchId, tokenIds[i]);
        }
    }

    function test_createAndRegister() public {
        (uint256 matchId, ) = _openMatch();
        assertEq(arena.entrantCount(matchId), N);
    }

    function test_startMatch_buildsTables() public {
        (uint256 matchId, bytes32 seed) = _openMatch();
        vm.warp(block.timestamp + 61);
        arena.startMatch(matchId, seed, 100e6);
        assertEq(arena.tablesAtStage(matchId, UnchainArena.Stage.Quarterfinal), N / 4);
        for (uint256 i = 0; i < N; i++) {
            assertTrue(arena.aliveOf(matchId, tokenIds[i]));
            assertGe(arena.hpOf(matchId, tokenIds[i]), 43);
        }
    }

    function test_startMatch_rejectsBadSeed() public {
        (uint256 matchId, ) = _openMatch();
        vm.warp(block.timestamp + 61);
        vm.expectRevert(bytes("bad seed"));
        arena.startMatch(matchId, keccak256("wrong"), 0);
    }

    function test_act_attack_recordsIntent() public {
        (uint256 matchId, bytes32 seed) = _openMatch();
        vm.warp(block.timestamp + 61);
        arena.startMatch(matchId, seed, 100e6);

        uint256 a = tokenIds[0];
        // find a target at the same table as tokenIds[0]
        uint256 table = arena.tableOf(matchId, a);
        uint256[] memory mates = arena.tableOfAt(matchId, UnchainArena.Stage.Quarterfinal, table);
        uint256 target = mates[0] == a ? mates[1] : mates[0];

        vm.prank(nft.ownerOf(a));
        arena.act(matchId, a, UnchainArena.ActionKind.Attack, target);
        assertTrue(arena.actedInRound(matchId, 0, a));
        (UnchainArena.ActionKind kind, uint256 recordedTgt) = arena.actionOf(matchId, 0, a);
        assertEq(uint8(kind), uint8(UnchainArena.ActionKind.Attack));
        assertEq(recordedTgt, target);
    }

    function test_act_rejectsDoubleSubmit() public {
        (uint256 matchId, bytes32 seed) = _openMatch();
        vm.warp(block.timestamp + 61);
        arena.startMatch(matchId, seed, 100e6);

        uint256 a = tokenIds[0];
        uint256 table = arena.tableOf(matchId, a);
        uint256[] memory mates = arena.tableOfAt(matchId, UnchainArena.Stage.Quarterfinal, table);
        uint256 target = mates[0] == a ? mates[1] : mates[0];

        vm.prank(nft.ownerOf(a));
        arena.act(matchId, a, UnchainArena.ActionKind.Wait, 0);
        vm.prank(nft.ownerOf(a));
        vm.expectRevert(bytes("already acted"));
        arena.act(matchId, a, UnchainArena.ActionKind.Attack, target);
    }

    function test_resolveRound_advancesClock() public {
        (uint256 matchId, bytes32 seed) = _openMatch();
        vm.warp(block.timestamp + 61);
        arena.startMatch(matchId, seed, 100e6);

        // Have everyone wait → no deaths → next round window
        vm.warp(block.timestamp + 31);
        arena.resolveRound(matchId);
        (, , , , , uint64 roundStart, uint32 round, , , , ) = arena.matches(matchId);
        assertEq(round, 1);
        assertEq(roundStart, uint64(block.timestamp));
    }

    function test_resolveRound_rejectsWhileWindowOpen() public {
        (uint256 matchId, bytes32 seed) = _openMatch();
        vm.warp(block.timestamp + 61);
        arena.startMatch(matchId, seed, 100e6);
        vm.expectRevert(bytes("window open"));
        arena.resolveRound(matchId);
    }

    function test_cancelMatch_refundsBasePool() public {
        bytes32 seed = keccak256("x");
        bytes32 seedHash = keccak256(abi.encodePacked(seed));
        uint64 regEnd = uint64(block.timestamp + 60);
        uint256 matchId = arena.createMatch(seedHash, 50e6, regEnd);
        // register fewer than MIN_ENTRANTS (just 2)
        vm.prank(players[0]); arena.register(matchId, tokenIds[0]);
        vm.prank(players[1]); arena.register(matchId, tokenIds[1]);
        uint256 before = usdc.balanceOf(operator);
        arena.cancelMatch(matchId);
        assertEq(usdc.balanceOf(operator), before + 50e6);
    }
}
