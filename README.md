# 🎟️ ChainLottery: A Provably Fair On-Chain Lottery

A production-style, round-based Ethereum lottery written in **Solidity**. It uses **Chainlink VRF v2.5** for verifiable randomness and is compatible with **Chainlink Automation** for trustless round closing. Tests use **Foundry**, including unit, fuzz and stateful invariant tests. It ships with an **ethers.js dApp** that runs a full local demo with one command.

## Why it's more than a basic lottery

| Concern | What most tutorials do | What ChainLottery does |
|---|---|---|
| Randomness | `block.timestamp` / `prevrandao` (miner-manipulable) | **Chainlink VRF v2.5**: cryptographically verifiable, tamper-proof |
| Ticket storage | push one address per ticket (O(tickets) gas) | **cumulative ranges per purchase**: a 100-ticket buy is one storage slot; winner found by **O(log n) binary search** |
| Paying winners | push ETH in the VRF callback (one reverting winner bricks the lottery) | **pull payments**, `withdraw()` with **CEI + reentrancy guard** |
| Who closes rounds | `onlyOwner` | **permissionless** `performUpkeep` (Chainlink Automation-compatible); no trusted operator |
| VRF never responds | funds stuck forever | `retryDraw()` after 1 h, then `cancelStuckRound()` after 1 day with **full refunds** |
| Admin powers | owner can pause everything or change price mid-round | pause blocks **only new entries**; config changes apply **from the next round**; fee **hard-capped at 10%**; 2-step ownership |
| Lonely rounds | draw with 1 player | requires **≥ 2 players**, otherwise the round is extended with tickets kept |

## Security properties (enforced by tests)

- **Solvency invariant**: `balance == currentPot + totalPendingWithdrawals + accruedFees + unclaimedRefunds`, checked across 8,000+ random action sequences
- **Conservation of ETH**: ETH deposited equals ETH withdrawn plus ETH still held
- **Fee bound**: fees can never exceed 10% of deposits
- **Fair selection**: fuzz-tested against a brute-force reference implementation for random ticket distributions and random words
- **Reentrancy**: an attacker contract that re-enters `withdraw()` steals nothing
- **Access control**: only the VRF coordinator can deliver randomness; stale or duplicate VRF responses are ignored rather than reverted (per Chainlink guidance)

```
forge test
  26 unit + fuzz tests (1,000 fuzz runs each)  ✔
  3 invariants × 128 runs × 64 calls           ✔
  Line coverage on ChainLottery.sol: 94%
```

## Architecture

```
 Player ──enter(n) + ETH──▶ ┌─────────────────────────────┐
                            │        ChainLottery         │
 Chainlink Automation ────▶ │ checkUpkeep / performUpkeep │──requestRandomWords──▶ Chainlink VRF v2.5
   (or anyone)              │                             │◀─fulfillRandomWords── (verifiable randomness)
                            │  winningTicket = rand % N   │
                            │  binary-search the owner    │
 Winner ──withdraw()──────▶ │  pull payment (CEI + guard) │
                            └─────────────────────────────┘
 Round lifecycle:  Open ──(time up, ≥2 players)──▶ Drawing ──(VRF)──▶ Settled ──▶ next round Open
                                                      └──(stuck 1 day)──▶ Refunded (claimRefund)
```

## Quick start (local demo, about 30 seconds)

Requires [Foundry](https://getfoundry.sh).

```bash
./demo.sh          # starts anvil, deploys a Chainlink VRF mock + funded subscription + the lottery, serves the dApp
```

Open **http://localhost:8003**. Local mode uses anvil's prefunded test accounts, so no MetaMask is needed:

1. Pick *Player 1*, buy some tickets. Switch to *Player 2*, buy more.
2. Click **⏩ Fast-forward 5 min**, then **🔒 Close round**, then **⚡ Deliver Chainlink VRF randomness**.
3. A winner is drawn, confetti 🎉, and the winner clicks **💰 Withdraw winnings**.

## Tests

```bash
forge test -vv            # all tests
forge test --gas-report   # gas usage per function
forge coverage            # coverage report
```

## Deploy to Sepolia

1. Create and fund a VRF v2.5 subscription at [vrf.chain.link](https://vrf.chain.link). Copy the coordinator address and key hash for Sepolia from the [Chainlink docs](https://docs.chain.link/vrf/v2-5/supported-networks).
2. Deploy:
   ```bash
   VRF_COORDINATOR=0x... VRF_KEY_HASH=0x... VRF_SUB_ID=... \
   forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC_URL --account deployer --broadcast --verify
   ```
3. Add the deployed lottery as a **consumer** on your subscription, then optionally register a **custom-logic upkeep** at [automation.chain.link](https://automation.chain.link).
4. Serve `frontend/` and connect MetaMask.

## Contract API

| Function | Who | Description |
|---|---|---|
| `enter(uint256 n)` | anyone | Buy `n` tickets (1–100), sending exactly `n × ticketPrice` |
| `withdraw()` | anyone | Withdraw prizes and refunds credited to you |
| `claimRefund(roundId)` | players | Reclaim your stake from a cancelled round |
| `checkUpkeep` / `performUpkeep` | Automation / anyone | Close an expired round and request randomness |
| `retryDraw()` | anyone | Re-request VRF if it hasn't arrived after 1 h |
| `cancelStuckRound()` | anyone | Cancel a draw stuck for 1 day and enable refunds |
| `setConfig` / `setVrfConfig` / `setPaused` / `withdrawFees` | owner | Admin, with the safety limits described above |
| `getRound`, `currentRound`, `getEntries`, `ownerOfTicket`, `winChanceBps` | view | Read state for frontends and indexers |

## Tech stack

Solidity 0.8.28 · Foundry (forge, anvil, cast) · Chainlink VRF v2.5 · Chainlink Automation · ethers.js v6 · HTML/CSS/JS · GitHub Actions
