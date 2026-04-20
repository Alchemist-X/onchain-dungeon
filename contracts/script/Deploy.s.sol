// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AdventurerNFT} from "../src/AdventurerNFT.sol";
import {BattleArena} from "../src/BattleArena.sol";

/// @notice Deploys AdventurerNFT + BattleArena to XLayer.
/// @dev Env vars required:
///   USDC_ADDRESS       — XLayer USDC contract (6 decimals)
///   PLATFORM_TREASURY  — address receiving 2 USDC per mint
///   OPERATOR           — address authorized to create/settle matches (defaults to deployer)
///
/// Usage (mainnet):
///   forge script script/Deploy.s.sol --rpc-url xlayer --broadcast --verify
contract Deploy is Script {
    function run() external returns (AdventurerNFT nft, BattleArena arena) {
        address usdc = vm.envAddress("USDC_ADDRESS");
        address treasury = vm.envAddress("PLATFORM_TREASURY");
        address operator = vm.envOr("OPERATOR", msg.sender);

        vm.startBroadcast();

        nft = new AdventurerNFT(usdc, treasury, msg.sender);
        arena = new BattleArena(usdc, address(nft), msg.sender);

        nft.setArena(address(arena));
        if (operator != msg.sender) {
            arena.setOperator(operator);
        }

        vm.stopBroadcast();

        console2.log("USDC          :", usdc);
        console2.log("Treasury      :", treasury);
        console2.log("Operator      :", operator);
        console2.log("AdventurerNFT :", address(nft));
        console2.log("BattleArena   :", address(arena));
    }
}
