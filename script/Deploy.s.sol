// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
import {ChainLottery} from "../src/ChainLottery.sol";

/// @notice Deploys ChainLottery using VRF_COORDINATOR, VRF_KEY_HASH and VRF_SUB_ID from the environment.
///         For local anvil runs, use ./demo.sh, which sets up a funded VRF mock subscription first.
///         Writes frontend/config.json so the dApp knows where everything lives.
contract Deploy is Script {
    function run() external returns (ChainLottery lottery) {
        uint128 price = uint128(vm.envOr("TICKET_PRICE_WEI", uint256(0.01 ether)));
        uint64 duration = uint64(vm.envOr("ROUND_SECONDS", uint256(block.chainid == 31337 ? 5 minutes : 1 days)));
        uint16 fee = uint16(vm.envOr("FEE_BPS", uint256(500)));

        // Subscription IDs are derived from on-chain state, so they must be created *before* this script runs
        // (forge simulates all txs in one block, which would produce a different ID than the real broadcast).
        // demo.sh does this automatically for anvil; on testnets create one at vrf.chain.link.
        address coordinator = vm.envAddress("VRF_COORDINATOR");
        bytes32 keyHash = vm.envBytes32("VRF_KEY_HASH");
        uint256 subId = vm.envUint("VRF_SUB_ID");

        vm.startBroadcast();
        lottery = new ChainLottery(
            coordinator,
            ChainLottery.VrfConfig({
                keyHash: keyHash,
                subscriptionId: subId,
                callbackGasLimit: 500_000,
                requestConfirmations: 3,
                nativePayment: false
            }),
            price,
            duration,
            fee
        );
        // On anvil the deployer owns the mock subscription, so register the consumer right away.
        if (block.chainid == 31337) VRFCoordinatorV2_5Mock(coordinator).addConsumer(subId, address(lottery));
        vm.stopBroadcast();

        string memory obj = "config";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "vrfCoordinator", coordinator);
        string memory json = vm.serializeAddress(obj, "lottery", address(lottery));
        vm.writeJson(json, "./frontend/config.json");

        console.log("ChainLottery deployed at", address(lottery));
        if (block.chainid != 31337) console.log("Next: add the lottery as a consumer on your VRF subscription");
    }
}
