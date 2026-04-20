// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AdventurerNFT} from "../src/AdventurerNFT.sol";
import {MockUSDC} from "./MockUSDC.sol";

contract AdventurerNFTTest is Test {
    AdventurerNFT nft;
    MockUSDC usdc;
    address treasury = address(0xBEEF);
    address arena = address(0xA7E);
    address alice = address(0xA11CE);

    function setUp() public {
        usdc = new MockUSDC();
        nft = new AdventurerNFT(address(usdc), treasury, address(this));
        nft.setArena(arena);
        nft.setPaymentsEnabled(true);
        usdc.mint(alice, 1000e6);
        vm.prank(alice);
        usdc.approve(address(nft), type(uint256).max);
    }

    function _mint() internal returns (uint256 id) {
        vm.prank(alice);
        id = nft.mint();
    }

    function test_mint_distributesUsdc() public {
        uint256 id = _mint();
        assertEq(nft.ownerOf(id), alice);
        assertEq(usdc.balanceOf(treasury), 2e6, "treasury 2 USDC");
        assertEq(nft.vaultOf(id), 3e6, "vault 3 USDC");
        assertEq(usdc.balanceOf(address(nft)), 3e6, "nft holds 3 USDC");
        assertTrue(nft.isAlive(id));
    }

    function test_mint_statsWithinBounds() public {
        for (uint256 i = 0; i < 10; i++) {
            vm.prevrandao(keccak256(abi.encode(i)));
            uint256 id = _mint();
            (uint8 s, uint8 a, uint8 l,,,,,, AdventurerNFT.Rarity rarity,,) = nft.statsOf(id);
            (uint8 total, uint8 cap) = _rarityParams(rarity);
            assertEq(uint256(s) + uint256(a) + uint256(l), uint256(total), "total pts");
            assertTrue(s <= cap && a <= cap && l <= cap, "cap");
            assertTrue(s >= 1 && a >= 1 && l >= 1, "min 1");
        }
    }

    function _rarityParams(AdventurerNFT.Rarity r) internal pure returns (uint8 total, uint8 cap) {
        if (r == AdventurerNFT.Rarity.Common) return (15, 7);
        if (r == AdventurerNFT.Rarity.Uncommon) return (17, 8);
        if (r == AdventurerNFT.Rarity.Rare) return (19, 9);
        if (r == AdventurerNFT.Rarity.Epic) return (21, 10);
        return (23, 10);
    }

    function test_enhance_increasesStatAndVault() public {
        uint256 id = _mint();
        (uint8 s0,,,,,,,,, ,) = nft.statsOf(id);
        vm.prank(alice);
        nft.enhance(id, 0);
        (uint8 s1,,, uint8 enhStr,,, uint8 enhCount,, ,,) = nft.statsOf(id);
        assertEq(s1, s0 + 1);
        assertEq(enhStr, 1);
        assertEq(enhCount, 1);
        assertEq(nft.vaultOf(id), 3e6 + 2e6);
    }

    function test_enhance_maxPerStat() public {
        uint256 id = _mint();
        for (uint8 i = 0; i < 5; i++) {
            vm.prank(alice);
            nft.enhance(id, 0);
        }
        vm.expectRevert(bytes("stat capped"));
        vm.prank(alice);
        nft.enhance(id, 0);
    }

    function test_enhance_maxTotal() public {
        uint256 id = _mint();
        // 5 STR + 5 AGI = 10 total, next should fail
        for (uint8 s = 0; s < 2; s++) {
            for (uint8 i = 0; i < 5; i++) {
                vm.prank(alice);
                nft.enhance(id, s);
            }
        }
        vm.expectRevert(bytes("max enh"));
        vm.prank(alice);
        nft.enhance(id, 2);
    }

    function test_retire_refunds90Percent() public {
        uint256 id = _mint();
        vm.prank(alice);
        nft.enhance(id, 0); // vault = 5e6
        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        nft.retire(id);
        uint256 refund = (5e6 * 90) / 100;
        assertEq(usdc.balanceOf(alice), balBefore + refund);
        assertEq(nft.totalDestroyed(), 5e6 - refund);
        assertFalse(nft.isAlive(id));
    }

    function test_slay_sendsVaultToArena() public {
        uint256 id = _mint();
        vm.prank(alice);
        nft.enhance(id, 1); // vault = 5e6
        uint256 balBefore = usdc.balanceOf(arena);
        vm.prank(arena);
        uint256 toArena = nft.slay(id);
        assertEq(toArena, (5e6 * 90) / 100);
        assertEq(usdc.balanceOf(arena), balBefore + toArena);
        assertEq(nft.totalDestroyed(), 5e6 - toArena);
        assertFalse(nft.isAlive(id));
    }

    function test_markRested_swallowsAtLimit() public {
        uint256 id = _mint();
        for (uint8 i = 0; i < 6; i++) {
            vm.prank(arena);
            bool swallowed = nft.markRested(id);
            assertFalse(swallowed);
        }
        vm.prank(arena);
        bool swallowed = nft.markRested(id);
        assertTrue(swallowed);
        assertFalse(nft.isAlive(id));
        assertEq(nft.totalDestroyed(), 3e6, "full vault destroyed");
    }

    function test_setPreset() public {
        uint256 id = _mint();
        vm.prank(alice);
        nft.setPreset(id, AdventurerNFT.PromptPreset.Aggressive);
        (,,,,,,,,, AdventurerNFT.PromptPreset preset,) = nft.statsOf(id);
        assertEq(uint8(preset), uint8(AdventurerNFT.PromptPreset.Aggressive));
    }

    function test_revert_onlyOwnerEnhance() public {
        uint256 id = _mint();
        vm.expectRevert(bytes("not owner"));
        nft.enhance(id, 0);
    }

    function test_revert_onlyArenaSlay() public {
        uint256 id = _mint();
        vm.expectRevert(bytes("not arena"));
        nft.slay(id);
    }

    function test_freeMintMode() public {
        nft.setPaymentsEnabled(false);
        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 id = nft.mint();
        assertEq(usdc.balanceOf(alice), balBefore, "no USDC spent");
        assertEq(usdc.balanceOf(treasury), 0, "treasury empty");
        assertEq(nft.vaultOf(id), 0, "vault empty");
        assertTrue(nft.isAlive(id));
        // enhance also free
        vm.prank(alice);
        nft.enhance(id, 0);
        assertEq(nft.vaultOf(id), 0, "still empty after enhance");
        (uint8 s,,,,,,,,,,) = nft.statsOf(id);
        assertGt(s, 0);
    }
}
