// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {
    AutomationCompatibleInterface
} from "@chainlink/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";

/// @title ChainLottery - a provably fair, round-based lottery
/// @notice Players buy tickets with ETH. When a round ends, Chainlink VRF supplies verifiable randomness and
///         one ticket wins the pot (minus a capped protocol fee). Winners pull their prize (pull-payment pattern).
/// @dev Design highlights:
///      - Tickets are stored as cumulative ranges per purchase, so a 100-ticket buy is one storage slot and the
///        winner is found with an O(log n) binary search instead of an O(tickets) array.
///      - Rounds can be closed by Chainlink Automation or by anyone once the timer expires (no trusted operator).
///      - Liveness: a stalled VRF request can be re-requested after VRF_RETRY_DELAY and, as a last resort, the
///        round can be cancelled after ROUND_CANCEL_DELAY so players reclaim their stake. Funds can never be stuck.
///      - Pausing only blocks new entries; draws, refunds and withdrawals always keep working.
///      - Solvency invariant: balance == currentPot + totalPendingWithdrawals + accruedFees + unclaimedRefunds.
contract ChainLottery is VRFConsumerBaseV2Plus, AutomationCompatibleInterface {
    // ------------------------------------------------------------------ types

    enum RoundState {
        Open,
        Drawing,
        Settled,
        Refunded
    }

    /// @dev One purchase. `cumulativeTickets` is the running total *after* this purchase, so the purchase owns
    ///      ticket numbers [previous.cumulativeTickets, cumulativeTickets).
    struct Entry {
        address player;
        uint96 cumulativeTickets;
    }

    struct Round {
        uint128 ticketPrice;
        uint128 pot;
        uint64 startTime;
        uint64 endTime;
        uint64 drawRequestedAt;
        uint32 playerCount;
        uint16 feeBps;
        RoundState state;
        uint96 totalTickets;
        address winner;
        uint256 requestId;
        uint256 randomWord;
    }

    struct VrfConfig {
        bytes32 keyHash;
        uint256 subscriptionId;
        uint32 callbackGasLimit;
        uint16 requestConfirmations;
        bool nativePayment;
    }

    // ------------------------------------------------------------------ constants

    uint16 public constant MAX_FEE_BPS = 1_000; // 10%
    uint256 public constant MAX_TICKETS_PER_TX = 100;
    uint32 public constant MIN_PLAYERS = 2;
    uint256 public constant MIN_ROUND_DURATION = 5 minutes;
    uint256 public constant VRF_RETRY_DELAY = 1 hours;
    uint256 public constant ROUND_CANCEL_DELAY = 1 days;

    // ------------------------------------------------------------------ storage

    uint256 public currentRoundId;
    mapping(uint256 roundId => Round) private s_rounds;
    mapping(uint256 roundId => Entry[]) private s_entries;
    mapping(uint256 roundId => mapping(address player => uint256)) public ticketsOf;
    mapping(uint256 requestId => uint256 roundId) public roundOfRequest;

    mapping(address => uint256) public pendingWithdrawals;
    uint256 public totalPendingWithdrawals;
    uint256 public unclaimedRefunds;
    uint256 public accruedFees;

    // config for the *next* round (each round snapshots price/fee at start, so changes never affect live players)
    uint128 public ticketPrice;
    uint64 public roundDuration;
    uint16 public feeBps;
    bool public paused;
    VrfConfig public vrfConfig;

    uint256 private s_lock = 1;

    // ------------------------------------------------------------------ events

    event RoundStarted(uint256 indexed roundId, uint256 ticketPrice, uint256 endTime);
    event TicketsPurchased(uint256 indexed roundId, address indexed player, uint256 tickets, uint256 totalTickets);
    event RoundExtended(uint256 indexed roundId, uint256 newEndTime);
    event DrawRequested(uint256 indexed roundId, uint256 indexed requestId);
    event WinnerPicked(uint256 indexed roundId, address indexed winner, uint256 prize, uint256 winningTicket);
    event RoundCancelled(uint256 indexed roundId);
    event Withdrawal(address indexed account, uint256 amount);
    event RefundCredited(uint256 indexed roundId, address indexed player, uint256 amount);
    event FeesWithdrawn(address indexed to, uint256 amount);
    event ConfigUpdated(uint256 ticketPrice, uint256 roundDuration, uint256 feeBps);
    event VrfConfigUpdated(bytes32 keyHash, uint256 subscriptionId, uint32 callbackGasLimit);
    event Paused(bool paused);

    // ------------------------------------------------------------------ errors

    error LotteryPaused();
    error RoundNotOpen();
    error RoundEnded();
    error RoundStillRunning();
    error InvalidTicketCount();
    error IncorrectPayment(uint256 expected, uint256 sent);
    error NotDrawing();
    error TooEarly(uint256 availableAt);
    error NotRefundable();
    error NothingToClaim();
    error TransferFailed();
    error InvalidConfig();
    error Reentrancy();

    modifier nonReentrant() {
        if (s_lock != 1) revert Reentrancy();
        s_lock = 2;
        _;
        s_lock = 1;
    }

    constructor(
        address vrfCoordinator,
        VrfConfig memory vrfConfig_,
        uint128 ticketPrice_,
        uint64 roundDuration_,
        uint16 feeBps_
    ) VRFConsumerBaseV2Plus(vrfCoordinator) {
        _setConfig(ticketPrice_, roundDuration_, feeBps_);
        _setVrfConfig(vrfConfig_);
        _startNewRound();
    }

    // ================================================================== player actions

    /// @notice Buy `numTickets` tickets in the current round. Send exactly `numTickets * ticketPrice` wei.
    function enter(uint256 numTickets) external payable {
        if (paused) revert LotteryPaused();
        uint256 roundId = currentRoundId;
        Round storage r = s_rounds[roundId];
        if (r.state != RoundState.Open) revert RoundNotOpen();
        if (block.timestamp >= r.endTime) revert RoundEnded();
        if (numTickets == 0 || numTickets > MAX_TICKETS_PER_TX) revert InvalidTicketCount();
        uint256 cost = numTickets * r.ticketPrice;
        if (msg.value != cost) revert IncorrectPayment(cost, msg.value);

        // forge-lint: disable-next-line(unsafe-typecast) numTickets <= MAX_TICKETS_PER_TX
        uint96 newTotal = r.totalTickets + uint96(numTickets);
        Entry[] storage entries = s_entries[roundId];
        uint256 len = entries.length;
        // Consecutive buys by the same player extend their range instead of adding a new entry.
        if (len != 0 && entries[len - 1].player == msg.sender) {
            entries[len - 1].cumulativeTickets = newTotal;
        } else {
            entries.push(Entry({player: msg.sender, cumulativeTickets: newTotal}));
        }
        if (ticketsOf[roundId][msg.sender] == 0) r.playerCount++;
        ticketsOf[roundId][msg.sender] += numTickets;
        r.totalTickets = newTotal;
        // forge-lint: disable-next-line(unsafe-typecast) total ETH supply is far below 2^128 wei
        r.pot += uint128(msg.value);

        emit TicketsPurchased(roundId, msg.sender, numTickets, newTotal);
    }

    /// @notice Withdraw prizes and refunds credited to the caller.
    function withdraw() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert NothingToClaim();
        pendingWithdrawals[msg.sender] = 0;
        totalPendingWithdrawals -= amount;
        emit Withdrawal(msg.sender, amount);
        // forge-lint: disable-next-line(reentrancy-eth) state is zeroed first (CEI) and nonReentrant holds the lock
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Credit the caller's stake from a cancelled round to their withdrawable balance.
    function claimRefund(uint256 roundId) external {
        if (s_rounds[roundId].state != RoundState.Refunded) revert NotRefundable();
        uint256 tickets = ticketsOf[roundId][msg.sender];
        if (tickets == 0) revert NothingToClaim();
        ticketsOf[roundId][msg.sender] = 0;
        uint256 amount = tickets * s_rounds[roundId].ticketPrice;
        unclaimedRefunds -= amount;
        _credit(msg.sender, amount);
        emit RefundCredited(roundId, msg.sender, amount);
    }

    // ================================================================== drawing (Chainlink Automation compatible)

    /// @inheritdoc AutomationCompatibleInterface
    function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded, bytes memory) {
        Round storage r = s_rounds[currentRoundId];
        upkeepNeeded = r.state == RoundState.Open && block.timestamp >= r.endTime;
        return (upkeepNeeded, "");
    }

    /// @inheritdoc AutomationCompatibleInterface
    /// @dev Permissionless: anyone may close an expired round, so the lottery never depends on one operator.
    function performUpkeep(bytes calldata) external override {
        Round storage r = s_rounds[currentRoundId];
        if (r.state != RoundState.Open) revert RoundNotOpen();
        if (block.timestamp < r.endTime) revert RoundStillRunning();

        if (r.playerCount < MIN_PLAYERS) {
            // Not enough players for a meaningful draw: keep the round (and its tickets) open for another period.
            // forge-lint: disable-next-line(unsafe-typecast) uint64 seconds overflow in ~5e11 years
            r.endTime = uint64(block.timestamp + roundDuration);
            emit RoundExtended(currentRoundId, r.endTime);
            return;
        }
        r.state = RoundState.Drawing;
        _requestRandomness(currentRoundId);
    }

    /// @notice Re-request randomness if the VRF callback hasn't arrived after VRF_RETRY_DELAY.
    ///         The previous request becomes stale and is ignored if it ever lands.
    function retryDraw() external {
        uint256 roundId = currentRoundId;
        Round storage r = s_rounds[roundId];
        if (r.state != RoundState.Drawing) revert NotDrawing();
        uint256 availableAt = r.drawRequestedAt + VRF_RETRY_DELAY;
        if (block.timestamp < availableAt) revert TooEarly(availableAt);
        _requestRandomness(roundId);
    }

    /// @notice Last-resort escape hatch: cancel a round whose draw has been stuck for ROUND_CANCEL_DELAY.
    ///         Every player can then reclaim their full stake via `claimRefund`.
    function cancelStuckRound() external {
        uint256 roundId = currentRoundId;
        Round storage r = s_rounds[roundId];
        if (r.state != RoundState.Drawing) revert NotDrawing();
        uint256 availableAt = r.drawRequestedAt + ROUND_CANCEL_DELAY;
        if (block.timestamp < availableAt) revert TooEarly(availableAt);
        r.state = RoundState.Refunded;
        unclaimedRefunds += r.pot;
        emit RoundCancelled(roundId);
        _startNewRound();
    }

    /// @dev VRF callback. Must not revert (Chainlink won't retry), so unknown/stale requests are ignored.
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal override {
        uint256 roundId = roundOfRequest[requestId];
        Round storage r = s_rounds[roundId];
        if (roundId == 0 || r.state != RoundState.Drawing || r.requestId != requestId) return;

        uint256 winningTicket = randomWords[0] % r.totalTickets;
        address winner = _ownerOfTicket(roundId, winningTicket);
        uint256 fee = (uint256(r.pot) * r.feeBps) / 10_000;
        uint256 prize = r.pot - fee;

        r.state = RoundState.Settled;
        r.winner = winner;
        r.randomWord = randomWords[0];
        accruedFees += fee;
        _credit(winner, prize);

        emit WinnerPicked(roundId, winner, prize, winningTicket);
        _startNewRound();
    }

    // ================================================================== admin

    /// @notice Update ticket price, duration and fee. Takes effect from the next round.
    function setConfig(uint128 ticketPrice_, uint64 roundDuration_, uint16 feeBps_) external onlyOwner {
        _setConfig(ticketPrice_, roundDuration_, feeBps_);
    }

    function setVrfConfig(VrfConfig calldata cfg) external onlyOwner {
        _setVrfConfig(cfg);
    }

    /// @notice Pause/unpause ticket sales. Draws, refunds and withdrawals are never blocked.
    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit Paused(paused_);
    }

    function withdrawFees(address payable to) external nonReentrant onlyOwner {
        if (to == address(0)) revert InvalidConfig();
        uint256 amount = accruedFees;
        if (amount == 0) revert NothingToClaim();
        accruedFees = 0;
        emit FeesWithdrawn(to, amount);
        // forge-lint: disable-next-line(reentrancy-eth) state is zeroed first (CEI) and nonReentrant holds the lock
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    // ================================================================== views

    function getRound(uint256 roundId) external view returns (Round memory) {
        return s_rounds[roundId];
    }

    function currentRound() external view returns (Round memory) {
        return s_rounds[currentRoundId];
    }

    function entryCount(uint256 roundId) external view returns (uint256) {
        return s_entries[roundId].length;
    }

    /// @notice Paginated purchase list for a round (keeps calls bounded for frontends/indexers).
    function getEntries(uint256 roundId, uint256 offset, uint256 limit) external view returns (Entry[] memory page) {
        Entry[] storage entries = s_entries[roundId];
        if (offset >= entries.length) return page;
        uint256 end = offset + limit > entries.length ? entries.length : offset + limit;
        page = new Entry[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            page[i - offset] = entries[i];
        }
    }

    /// @notice Owner of ticket number `ticket` (0-indexed) in `roundId`.
    function ownerOfTicket(uint256 roundId, uint256 ticket) external view returns (address) {
        if (ticket >= s_rounds[roundId].totalTickets) revert InvalidTicketCount();
        return _ownerOfTicket(roundId, ticket);
    }

    /// @notice Probability (in basis points) that `player` wins the current round.
    function winChanceBps(address player) external view returns (uint256) {
        uint256 total = s_rounds[currentRoundId].totalTickets;
        return total == 0 ? 0 : (ticketsOf[currentRoundId][player] * 10_000) / total;
    }

    // ================================================================== internals

    function _requestRandomness(uint256 roundId) private {
        VrfConfig memory cfg = vrfConfig;
        uint256 requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: cfg.keyHash,
                subId: cfg.subscriptionId,
                requestConfirmations: cfg.requestConfirmations,
                callbackGasLimit: cfg.callbackGasLimit,
                numWords: 1,
                extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: cfg.nativePayment}))
            })
        );
        // The request ID is only known after the call; the coordinator is a trusted, immutable-by-owner contract.
        Round storage r = s_rounds[roundId];
        r.requestId = requestId;
        // forge-lint: disable-next-line(unsafe-typecast) uint64 seconds overflow in ~5e11 years
        r.drawRequestedAt = uint64(block.timestamp);
        roundOfRequest[requestId] = roundId;
        // forge-lint: disable-next-line(reentrancy-events) trusted coordinator; requestId unknown before the call
        emit DrawRequested(roundId, requestId);
    }

    /// @dev Binary search for the first entry whose cumulative count exceeds `ticket`.
    function _ownerOfTicket(uint256 roundId, uint256 ticket) private view returns (address) {
        Entry[] storage entries = s_entries[roundId];
        uint256 lo = 0;
        uint256 hi = entries.length - 1;
        while (lo < hi) {
            uint256 mid = (lo + hi) >> 1;
            if (entries[mid].cumulativeTickets > ticket) hi = mid;
            else lo = mid + 1;
        }
        return entries[lo].player;
    }

    function _startNewRound() private {
        uint256 roundId = ++currentRoundId;
        Round storage r = s_rounds[roundId];
        r.ticketPrice = ticketPrice;
        r.feeBps = feeBps;
        // forge-lint: disable-next-line(unsafe-typecast) uint64 seconds overflow in ~5e11 years
        r.startTime = uint64(block.timestamp);
        // forge-lint: disable-next-line(unsafe-typecast)
        r.endTime = uint64(block.timestamp + roundDuration);
        emit RoundStarted(roundId, r.ticketPrice, r.endTime);
    }

    function _credit(address account, uint256 amount) private {
        pendingWithdrawals[account] += amount;
        totalPendingWithdrawals += amount;
    }

    function _setConfig(uint128 ticketPrice_, uint64 roundDuration_, uint16 feeBps_) private {
        if (ticketPrice_ == 0 || roundDuration_ < MIN_ROUND_DURATION || feeBps_ > MAX_FEE_BPS) revert InvalidConfig();
        ticketPrice = ticketPrice_;
        roundDuration = roundDuration_;
        feeBps = feeBps_;
        emit ConfigUpdated(ticketPrice_, roundDuration_, feeBps_);
    }

    function _setVrfConfig(VrfConfig memory cfg) private {
        if (cfg.keyHash == bytes32(0) || cfg.subscriptionId == 0 || cfg.callbackGasLimit < 100_000) {
            revert InvalidConfig();
        }
        vrfConfig = cfg;
        emit VrfConfigUpdated(cfg.keyHash, cfg.subscriptionId, cfg.callbackGasLimit);
    }
}
