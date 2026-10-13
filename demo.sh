#!/usr/bin/env bash
# One-command local demo: local chain + deploy (with VRF mock) + dApp on http://localhost:8003
set -e
cd "$(dirname "$0")"
export PATH="$PATH:$HOME/.foundry/bin"
ANVIL_PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80   # anvil's public test key #0

anvil --silent --port 8545 &
ANVIL_PID=$!
trap 'kill $ANVIL_PID 2>/dev/null' EXIT
until cast block-number --rpc-url http://127.0.0.1:8545 >/dev/null 2>&1; do sleep 0.3; done
cast rpc evm_mine --rpc-url http://127.0.0.1:8545 >/dev/null   # VRF mock reads blockhash(block.number - 1)

RPC=http://127.0.0.1:8545
forge build --silent

# 1) Chainlink VRF v2.5 mock + funded subscription (ID read back from chain state)
MOCK=$(forge create lib/chainlink-brownie-contracts/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol:VRFCoordinatorV2_5Mock \
  --rpc-url $RPC --private-key $ANVIL_PK --broadcast --json \
  --constructor-args 100000000000000000 1000000000 4000000000000000 \
  | python3 -c "import sys,json;t=sys.stdin.read();print(json.loads(t[t.index('{'):])['deployedTo'])")
cast send $MOCK "createSubscription()" --rpc-url $RPC --private-key $ANVIL_PK >/dev/null
SUB=$(cast call $MOCK "getActiveSubscriptionIds(uint256,uint256)(uint256[])" 0 1 --rpc-url $RPC | python3 -c "import sys,re;print(re.findall(r'\d+',sys.stdin.read())[0])")
cast send $MOCK "fundSubscription(uint256,uint256)" $SUB 1000ether --rpc-url $RPC --private-key $ANVIL_PK >/dev/null

# 2) Lottery (5-minute rounds locally)
VRF_COORDINATOR=$MOCK VRF_SUB_ID=$SUB VRF_KEY_HASH=$(cast keccak local-key-hash) \
  forge script script/Deploy.s.sol --rpc-url $RPC --broadcast --private-key $ANVIL_PK --silent
python3 -c "import json;json.dump(json.load(open('out/ChainLottery.sol/ChainLottery.json'))['abi'],open('frontend/abi.json','w'))"

echo ""
echo "  ChainLottery is live → http://localhost:8003   (Ctrl+C to stop)"
echo ""
python3 -m http.server 8003 --bind 127.0.0.1 -d frontend >/dev/null 2>&1
