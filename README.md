# Gearbox Limit Orders

Smart contracts for the bot that allows executing signed limit orders in [Gearbox V2.1](https://github.com/Gearbox-protocol/core-v2/tree/v2.1).

## Description

This bot allows Gearbox users to place orders to swap assets in their credit accounts when certain conditions are met.
The main use case is the ability to create stop-loss and take-profit sell orders.

In order to use the bot, one must first approve it in the bot list.
Then, the user can start creating orders, which are signed EIP-712 messages containing information like input and output assets, minimum execution price and, optionally, trigger price (an upper bound on oracle price at which this order can be executed).

These signed orders are then passed to bot keepers who search for best ways to execute them via Gearbox multicalls.
The bot makes sure that provided multicall indeed swaps assets at the desired rate and doesn't perform any malicious or unintended activity.
Keepers can receive bounty to compensate their efforts and execution costs.

More details on order structure and multicall restrictions can be found in the contract's source code comments.

## Installation and testing

Install the project:

```bash
git clone git@github.com:lekhovitsky/gearbox-limit-orders.git
cd gearbox-limit-orders
forge install
```

Create a `.env` file with `RPC_URL` and `ETHERSCAN_API_KEY` fields.

To run the tests, execute `./scripts/test.sh`.
