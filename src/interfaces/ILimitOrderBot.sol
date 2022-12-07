// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import { MultiCall } from "@gearbox-protocol/core-v2/contracts/libraries/MultiCall.sol";


interface ILimitOrderBot {
    /// @notice Limit order data.
    struct Order {
        address borrower;
        // address of the token to sell
        address tokenIn;
        // address of the token to receive
        address tokenOut;
        // amount of tokenIn to sell
        uint256 amountIn;
        // min effective price at which tokenIn is sold for tokenOut
        uint256 minPriceWAD;
        // if non-zero, maximum oracle price at which order can be executed
        uint256 triggerPriceWAD;
    }

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

    /// @dev When order can't be executed because it's incorrectly constructed
    ///      (tokenIn and tokenOut are the same, or account doesn't have tokenIn)
    ///      or the trigger condition isn't satisfied.
    error InvalidOrder();

    /// @dev When calling unsupported adapter in a multicall.
    error InvalidCallTarget();

    /// @dev When calling unsupported method of supported adapter in a multicall.
    error InvalidCallMethod();

    /// @dev When calling supported method with wrong params in a multicall.
    error InvalidCallParams();

    /// @dev When multicall doesn't sell the required amount of order's input token.
    error InvalidAmountSold();

    /// @notice Order type hash for EIP-712 signature.
    function ORDER_TYPEHASH() external pure returns (bytes32);

    /// @notice Domain separator for EIP-712 signature.
    function DOMAIN_SEPARATOR() external view returns (bytes32);

    /// @notice Borrower's current nonce for EIP-712 signature.
    function nonces(address borrower) external view returns (uint256);

    /// @notice Executes a signed limit order with given multicall.
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
