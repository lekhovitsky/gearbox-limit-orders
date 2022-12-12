source .env

forge test \
    --fork-url $RPC_URL \
    --fork-block-number 16000000 \
    --etherscan-api-key $ETHERSCAN_API_KEY \
    --via-ir \
    -vvv
