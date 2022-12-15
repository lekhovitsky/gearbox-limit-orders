// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import { MultiCall } from "@gearbox-protocol/core-v2/contracts/libraries/MultiCall.sol";


/// @notice Limit order data.
struct Order {
    // address of the borrower who signed the order
    address borrower;
    // address of the token to sell
    address tokenIn;
    // address of the token to receive
    address tokenOut;
    // amount of tokenIn to sell
    uint256 amountIn;
    // min effective price at which tokenIn is sold for tokenOut
    uint256 minPrice;
    // if non-zero, maximum oracle price at which order can be executed
    uint256 triggerPrice;
}


/// @title Gearbox limit order bot interface.
interface ILimitOrderBot {

    /// @notice Emitted when limit order is successfully executed.
    /// @param borrower Borrower address.
    /// @param tokenIn Address of the token that was sold from borrower's credit account.
    /// @param tokenOut Address of the token that was received by credit account.
    /// @param amountIn Actual amount of the input token sold.
    event OrderExecuted(
        address indexed borrower,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn
    );

    /// @dev When provided signature is invalid for a given order.
    error InvalidSignature();

    /// @dev When order can't be executed because it's incorrectly constructed.
    error InvalidOrder();

    /// @dev When trying to execute an order when trigger condition is not met.
    error NotTriggered();

    /// @dev When account doesn't have input token to sell.
    error NothingToSell();

    /// @dev When calling unsupported adapter in a multicall.
    error InvalidCallTarget();

    /// @dev When calling unsupported method of supported adapter in a multicall.
    error InvalidCallMethod();

    /// @dev When multicall doesn't sell the required amount of order's input token.
    error InvalidAmountSold();

    /// @notice Order type hash for EIP-712 signature.
    function ORDER_TYPEHASH() external pure returns (bytes32);

    /// @notice Domain separator for EIP-712 signature.
    function DOMAIN_SEPARATOR() external view returns (bytes32);

    /// @notice Borrower's current nonce for EIP-712 signature.
    function nonces(address borrower) external view returns (uint256);

    /// @notice Executes a signed limit order via provided multicall.
    /// @dev In order for multicall to be valid, the following must hold:
    /// * Each subcall executes one of supported methods, which are all exact input
    ///   swaps of Uniswap V2, Uniswap V3 and Sushiswap.
    /// * Multicall sells precisely the specified amount of the input token.
    ///   If account's balance is smaller than order size, all balance must be sold.
    /// * For any token spent during the multicall except for the order input token,
    ///   its balance after the multicall must be at least that before.
    /// * Effective price for the user must be at least that specified in the order.
    /// @dev Caller can pay themself a bounty via `UniversalAdapter.withdrawTo` call
    ///   as long as all balance conditions above hold.
    /// @param calls Operations needed to execute the order.
    /// @param order Limit order data.
    /// @param v Signature component.
    /// @param r Signature component.
    /// @param s Signature component.
    function executeOrder(
        MultiCall[] calldata calls,
        Order calldata order,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    /// @notice Bumps sender's nonce which invalidates all outstanding orders.
    function bumpNonce() external;
}
