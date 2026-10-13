// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VRFCoordinatorV2_5Mock} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
import {ChainLottery} from "../src/ChainLottery.sol";

abstract contract LotteryBase is Test {
    VRFCoordinatorV2_5Mock internal vrf;
    ChainLottery internal lottery;
    uint256 internal subId;

    uint128 internal constant PRICE = 0.01 ether;
    uint64 internal constant DURATION = 1 hours;
    uint16 internal constant FEE_BPS = 500; // 5%

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public virtual {
        vrf = new VRFCoordinatorV2_5Mock(0.1 ether, 1e9, 4e15);
        subId = vrf.createSubscription();
        vrf.fundSubscription(subId, 1_000 ether);
        lottery = new ChainLottery(
            address(vrf),
            ChainLottery.VrfConfig({
                keyHash: keccak256("keyHash"),
                subscriptionId: subId,
                callbackGasLimit: 500_000,
                requestConfirmations: 3,
                nativePayment: false
            }),
            PRICE,
            DURATION,
            FEE_BPS
        );
        vrf.addConsumer(subId, address(lottery));
        for (uint256 i; i < 3; ++i) {
            vm.deal([alice, bob, carol][i], 100 ether);
        }
    }

    function _buy(address who, uint256 n) internal {
        vm.prank(who);
        lottery.enter{value: n * PRICE}(n);
    }

    function _closeRound() internal returns (uint256 requestId) {
        vm.warp(block.timestamp + DURATION);
        lottery.performUpkeep("");
        requestId = lottery.currentRound().requestId;
    }

    function _fulfill(uint256 requestId, uint256 word) internal {
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        vrf.fulfillRandomWordsWithOverride(requestId, address(lottery), words);
    }

    function _assertSolvent() internal view {
        assertEq(
            address(lottery).balance,
            uint256(lottery.currentRound().pot) + lottery.totalPendingWithdrawals() + lottery.accruedFees()
                + lottery.unclaimedRefunds(),
            "solvency"
        );
    }
}

contract ChainLotteryTest is LotteryBase {
    // ------------------------------------------------------------ entering

    function test_InitialRoundIsOpen() public view {
        ChainLottery.Round memory r = lottery.currentRound();
        assertEq(lottery.currentRoundId(), 1);
        assertEq(uint8(r.state), uint8(ChainLottery.RoundState.Open));
        assertEq(r.ticketPrice, PRICE);
        assertEq(r.endTime, block.timestamp + DURATION);
    }

    function test_EnterRecordsTicketsAndPot() public {
        _buy(alice, 3);
        _buy(bob, 2);
        ChainLottery.Round memory r = lottery.currentRound();
        assertEq(r.totalTickets, 5);
        assertEq(r.pot, 5 * PRICE);
        assertEq(r.playerCount, 2);
        assertEq(lottery.ticketsOf(1, alice), 3);
        assertEq(lottery.winChanceBps(alice), 6_000);
        _assertSolvent();
    }

    function test_ConsecutiveBuysMergeIntoOneEntry() public {
        _buy(alice, 2);
        _buy(alice, 5);
        _buy(bob, 1);
        _buy(alice, 1);
        assertEq(lottery.entryCount(1), 3); // [alice x7][bob x1][alice x1]
        assertEq(lottery.currentRound().playerCount, 2);
        assertEq(lottery.ownerOfTicket(1, 6), alice);
        assertEq(lottery.ownerOfTicket(1, 7), bob);
        assertEq(lottery.ownerOfTicket(1, 8), alice);
    }

    function test_RevertWhen_WrongPayment() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ChainLottery.IncorrectPayment.selector, 2 * PRICE, PRICE));
        lottery.enter{value: PRICE}(2);
    }

    function test_RevertWhen_InvalidTicketCount() public {
        vm.startPrank(alice);
        vm.expectRevert(ChainLottery.InvalidTicketCount.selector);
        lottery.enter{value: 0}(0);
        vm.expectRevert(ChainLottery.InvalidTicketCount.selector);
        lottery.enter{value: 101 * PRICE}(101);
        vm.stopPrank();
    }

    function test_RevertWhen_RoundEnded() public {
        vm.warp(block.timestamp + DURATION);
        vm.prank(alice);
        vm.expectRevert(ChainLottery.RoundEnded.selector);
        lottery.enter{value: PRICE}(1);
    }

    function test_RevertWhen_Paused() public {
        lottery.setPaused(true);
        vm.prank(alice);
        vm.expectRevert(ChainLottery.LotteryPaused.selector);
        lottery.enter{value: PRICE}(1);
    }

    function test_RevertWhen_PlainEthTransfer() public {
        vm.prank(alice);
        (bool ok,) = address(lottery).call{value: 1 ether}("");
        assertFalse(ok);
    }

    // ------------------------------------------------------------ upkeep

    function test_CheckUpkeepOnlyAfterEnd() public {
        (bool needed,) = lottery.checkUpkeep("");
        assertFalse(needed);
        vm.warp(block.timestamp + DURATION);
        (needed,) = lottery.checkUpkeep("");
        assertTrue(needed);
    }

    function test_RevertWhen_UpkeepBeforeEnd() public {
        vm.expectRevert(ChainLottery.RoundStillRunning.selector);
        lottery.performUpkeep("");
    }

    function test_RoundExtendsWithTooFewPlayers() public {
        _buy(alice, 10);
        vm.warp(block.timestamp + DURATION);
        lottery.performUpkeep("");
        ChainLottery.Round memory r = lottery.currentRound();
        assertEq(uint8(r.state), uint8(ChainLottery.RoundState.Open));
        assertEq(r.endTime, block.timestamp + DURATION);
        assertEq(r.totalTickets, 10); // tickets carried over
        assertEq(lottery.currentRoundId(), 1);
    }

    function test_EntriesBlockedWhileDrawing() public {
        _buy(alice, 1);
        _buy(bob, 1);
        _closeRound();
        vm.prank(carol);
        vm.expectRevert(ChainLottery.RoundNotOpen.selector);
        lottery.enter{value: PRICE}(1);
    }

    // ------------------------------------------------------------ drawing

    function test_FullRoundPicksCorrectWinnerAndStartsNewRound() public {
        _buy(alice, 3); // tickets 0-2
        _buy(bob, 5); // tickets 3-7
        _buy(carol, 2); // tickets 8-9
        uint256 requestId = _closeRound();
        assertEq(uint8(lottery.currentRound().state), uint8(ChainLottery.RoundState.Drawing));

        _fulfill(requestId, 1_000_004); // 1_000_004 % 10 = 4 -> bob

        ChainLottery.Round memory r = lottery.getRound(1);
        assertEq(uint8(r.state), uint8(ChainLottery.RoundState.Settled));
        assertEq(r.winner, bob);
        uint256 pot = 10 * PRICE;
        uint256 fee = (pot * FEE_BPS) / 10_000;
        assertEq(lottery.pendingWithdrawals(bob), pot - fee);
        assertEq(lottery.accruedFees(), fee);
        assertEq(lottery.currentRoundId(), 2);
        assertEq(uint8(lottery.currentRound().state), uint8(ChainLottery.RoundState.Open));
        _assertSolvent();
    }

    function test_WinnerWithdrawsPrize() public {
        _buy(alice, 1);
        _buy(bob, 1);
        _fulfill(_closeRound(), 0); // ticket 0 -> alice
        uint256 owed = lottery.pendingWithdrawals(alice);
        uint256 before = alice.balance;
        vm.prank(alice);
        lottery.withdraw();
        assertEq(alice.balance, before + owed);
        assertEq(lottery.pendingWithdrawals(alice), 0);
        vm.prank(alice);
        vm.expectRevert(ChainLottery.NothingToClaim.selector);
        lottery.withdraw();
        _assertSolvent();
    }

    function test_RevertWhen_NonCoordinatorFulfills() public {
        _buy(alice, 1);
        _buy(bob, 1);
        uint256 requestId = _closeRound();
        uint256[] memory words = new uint256[](1);
        vm.prank(alice);
        vm.expectRevert();
        lottery.rawFulfillRandomWords(requestId, words);
    }

    function test_RetryDrawIgnoresStaleRequest() public {
        _buy(alice, 1);
        _buy(bob, 1);
        uint256 oldRequest = _closeRound();
        vm.expectRevert(
            abi.encodeWithSelector(ChainLottery.TooEarly.selector, block.timestamp + lottery.VRF_RETRY_DELAY())
        );
        lottery.retryDraw();

        vm.warp(block.timestamp + lottery.VRF_RETRY_DELAY());
        lottery.retryDraw();
        uint256 newRequest = lottery.currentRound().requestId;
        assertTrue(newRequest != oldRequest);

        _fulfill(oldRequest, 1); // stale: ignored
        assertEq(uint8(lottery.getRound(1).state), uint8(ChainLottery.RoundState.Drawing));
        _fulfill(newRequest, 1); // ticket 1 -> bob
        assertEq(lottery.getRound(1).winner, bob);
    }

    function test_CancelStuckRoundRefundsEveryone() public {
        _buy(alice, 3);
        _buy(bob, 1);
        _closeRound();
        vm.warp(block.timestamp + lottery.ROUND_CANCEL_DELAY());
        lottery.cancelStuckRound();
        assertEq(uint8(lottery.getRound(1).state), uint8(ChainLottery.RoundState.Refunded));
        assertEq(lottery.currentRoundId(), 2);
        _assertSolvent();

        vm.startPrank(alice);
        lottery.claimRefund(1);
        vm.expectRevert(ChainLottery.NothingToClaim.selector);
        lottery.claimRefund(1);
        uint256 before = alice.balance;
        lottery.withdraw();
        vm.stopPrank();
        assertEq(alice.balance, before + 3 * PRICE);
        _assertSolvent();
    }

    function test_RevertWhen_RefundOnSettledRound() public {
        _buy(alice, 1);
        _buy(bob, 1);
        _fulfill(_closeRound(), 0);
        vm.prank(bob);
        vm.expectRevert(ChainLottery.NotRefundable.selector);
        lottery.claimRefund(1);
    }

    // ------------------------------------------------------------ admin

    function test_ConfigAppliesToNextRoundOnly() public {
        lottery.setConfig(0.05 ether, 2 hours, 300);
        assertEq(lottery.currentRound().ticketPrice, PRICE); // live round unchanged
        _buy(alice, 1);
        _buy(bob, 1);
        _fulfill(_closeRound(), 0);
        assertEq(lottery.currentRound().ticketPrice, 0.05 ether);
        assertEq(lottery.currentRound().feeBps, 300);
    }

    function test_RevertWhen_FeeAboveCap() public {
        vm.expectRevert(ChainLottery.InvalidConfig.selector);
        lottery.setConfig(PRICE, DURATION, 1_001);
    }

    function test_RevertWhen_NonOwnerAdmin() public {
        vm.startPrank(alice);
        vm.expectRevert("Only callable by owner");
        lottery.setPaused(true);
        vm.expectRevert("Only callable by owner");
        lottery.withdrawFees(payable(alice));
        vm.stopPrank();
    }

    function test_OwnerWithdrawsFees() public {
        _buy(alice, 10);
        _buy(bob, 10);
        _fulfill(_closeRound(), 0);
        uint256 fees = lottery.accruedFees();
        address treasury = makeAddr("treasury");
        lottery.withdrawFees(payable(treasury));
        assertEq(treasury.balance, fees);
        assertEq(lottery.accruedFees(), 0);
        _assertSolvent();
    }

    function test_PauseNeverBlocksWithdrawals() public {
        _buy(alice, 1);
        _buy(bob, 1);
        _fulfill(_closeRound(), 0);
        lottery.setPaused(true);
        vm.prank(alice);
        lottery.withdraw(); // still works
    }

    // ------------------------------------------------------------ security

    function test_ReentrancyAttackFails() public {
        Reenterer attacker = new Reenterer(lottery);
        vm.deal(address(attacker), 1 ether);
        attacker.buy(1);
        _buy(bob, 1);
        _fulfill(_closeRound(), 0); // ticket 0 -> attacker
        uint256 owed = lottery.pendingWithdrawals(address(attacker));
        vm.expectRevert(ChainLottery.TransferFailed.selector); // inner re-entry reverts -> whole call reverts
        attacker.attack();
        assertEq(lottery.pendingWithdrawals(address(attacker)), owed); // nothing stolen
        _assertSolvent();
    }

    // ------------------------------------------------------------ fuzz

    /// @dev Winner selection must match a naive linear scan for any ticket distribution and random word.
    function testFuzz_WinnerMatchesLinearScan(uint8[6] memory buys, uint256 word) public {
        address[3] memory players = [alice, bob, carol];
        address[] memory owners = new address[](600);
        uint256 total;
        for (uint256 i; i < buys.length; ++i) {
            uint256 n = bound(buys[i], 1, 100);
            address p = players[i % 3];
            _buy(p, n);
            for (uint256 k; k < n; ++k) {
                owners[total++] = p;
            }
        }
        uint256 requestId = _closeRound();
        _fulfill(requestId, word);
        assertEq(lottery.getRound(1).winner, owners[word % total]);
        _assertSolvent();
    }

    function testFuzz_PrizePlusFeeEqualsPot(uint8 a, uint8 b, uint256 word) public {
        uint256 na = bound(a, 1, 100);
        uint256 nb = bound(b, 1, 100);
        _buy(alice, na);
        _buy(bob, nb);
        _fulfill(_closeRound(), word);
        address winner = lottery.getRound(1).winner;
        assertEq(lottery.pendingWithdrawals(winner) + lottery.accruedFees(), (na + nb) * PRICE);
    }
}

contract Reenterer {
    ChainLottery internal immutable lottery;

    constructor(ChainLottery l) {
        lottery = l;
    }

    function buy(uint256 n) external {
        lottery.enter{value: n * lottery.ticketPrice()}(n);
    }

    function attack() external {
        lottery.withdraw();
    }

    receive() external payable {
        lottery.withdraw(); // try to withdraw again mid-transfer
    }
}
