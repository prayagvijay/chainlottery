// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
import {ChainLottery} from "../src/ChainLottery.sol";
import {LotteryBase} from "./ChainLottery.t.sol";

/// @dev Drives random sequences of player/keeper/VRF actions against the lottery.
contract Handler is Test {
    ChainLottery internal lottery;
    VRFCoordinatorV2_5Mock internal vrf;
    address[] internal actors;
    uint256 public ghostDeposited;
    uint256 public ghostWithdrawn;

    constructor(ChainLottery l, VRFCoordinatorV2_5Mock v) {
        lottery = l;
        vrf = v;
        for (uint256 i; i < 5; ++i) {
            address a = makeAddr(string(abi.encodePacked("actor", i)));
            vm.deal(a, 1_000 ether);
            actors.push(a);
        }
    }

    function enter(uint256 actorSeed, uint256 n) external {
        ChainLottery.Round memory r = lottery.currentRound();
        if (r.state != ChainLottery.RoundState.Open || block.timestamp >= r.endTime) return;
        n = bound(n, 1, 100);
        address a = actors[actorSeed % actors.length];
        vm.prank(a);
        lottery.enter{value: n * r.ticketPrice}(n);
        ghostDeposited += n * r.ticketPrice;
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 2 days));
    }

    function upkeep() external {
        (bool needed,) = lottery.checkUpkeep("");
        if (needed) lottery.performUpkeep("");
    }

    function fulfill(uint256 word) external {
        ChainLottery.Round memory r = lottery.currentRound();
        if (r.state != ChainLottery.RoundState.Drawing) return;
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        vrf.fulfillRandomWordsWithOverride(r.requestId, address(lottery), words);
    }

    function cancelStuck() external {
        ChainLottery.Round memory r = lottery.currentRound();
        if (
            r.state == ChainLottery.RoundState.Drawing
                && block.timestamp >= r.drawRequestedAt + lottery.ROUND_CANCEL_DELAY()
        ) {
            lottery.cancelStuckRound();
        }
    }

    function claimRefunds(uint256 roundSeed) external {
        uint256 roundId = bound(roundSeed, 1, lottery.currentRoundId());
        if (lottery.getRound(roundId).state != ChainLottery.RoundState.Refunded) return;
        for (uint256 i; i < actors.length; ++i) {
            if (lottery.ticketsOf(roundId, actors[i]) > 0) {
                vm.prank(actors[i]);
                lottery.claimRefund(roundId);
            }
        }
    }

    function withdraw(uint256 actorSeed) external {
        address a = actors[actorSeed % actors.length];
        uint256 owed = lottery.pendingWithdrawals(a);
        if (owed == 0) return;
        vm.prank(a);
        lottery.withdraw();
        ghostWithdrawn += owed;
    }
}

contract ChainLotteryInvariantTest is LotteryBase {
    Handler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new Handler(lottery, vrf);
        targetContract(address(handler));
    }

    /// @notice The contract always holds exactly what it owes: live pot + prizes/refunds owed + fees.
    function invariant_Solvency() public view {
        _assertSolvent();
    }

    /// @notice ETH in == ETH out + ETH still held (no value created or destroyed).
    function invariant_ConservationOfEth() public view {
        assertEq(handler.ghostDeposited(), handler.ghostWithdrawn() + address(lottery).balance);
    }

    /// @notice Fees can never exceed the configured cap of the total deposited.
    function invariant_FeesBounded() public view {
        assertLe(lottery.accruedFees(), (handler.ghostDeposited() * lottery.MAX_FEE_BPS()) / 10_000);
    }
}
