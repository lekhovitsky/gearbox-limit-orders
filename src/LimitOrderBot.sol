// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import { ILimitOrderBot, Order } from "./interfaces/ILimitOrderBot.sol";

import { Counters } from "@openzeppelin/contracts/utils/Counters.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";

import { Balance } from "@gearbox-protocol/core-v2/contracts/libraries/Balances.sol";
import { MultiCall } from "@gearbox-protocol/core-v2/contracts/libraries/MultiCall.sol";
import { ICreditManagerV2 } from "@gearbox-protocol/core-v2/contracts/interfaces/ICreditManagerV2.sol";
import { IUniversalAdapter } from "@gearbox-protocol/core-v2/contracts/interfaces/adapters/IUniversalAdapter.sol";
import { ICreditFacade, ICreditFacadeExtended } from "@gearbox-protocol/core-v2/contracts/interfaces/ICreditFacade.sol";

import { ISwapRouter } from "@gearbox-protocol/integrations-v2/contracts/integrations/uniswap/IUniswapV3.sol";
import { IUniswapV3Adapter } from "@gearbox-protocol/integrations-v2/contracts/interfaces/uniswap/IUniswapV3Adapter.sol";
import { IUniswapV2Adapter } from "@gearbox-protocol/integrations-v2/contracts/interfaces/uniswap/IUniswapV2Adapter.sol";
import { IUniswapV2Router01 } from "@gearbox-protocol/integrations-v2/contracts/integrations/uniswap/IUniswapV2Router01.sol";


/// @title Gearbox limit order bot.
/// @author Dmitry Lekhovitsky.
/// @notice Allows third parties to execute signed orders to sell assets in users
///         credit accounts on their behalf if certain conditions are met.
contract LimitOrderBot is ILimitOrderBot, EIP712 {
    using Counters for Counters.Counter;

    mapping(address => Counters.Counter) private _nonces;
    bytes32 private constant _ORDER_TYPEHASH = keccak256(
        "Order(address borrower,address tokenIn,address tokenOut,uint256 amountIn,"
        "uin256 minPrice,uint256 triggerPrice,uint256 nonce)"
    );

    /// @dev Credit Manager this bot is connected to.
    ICreditManagerV2 private immutable manager;
    /// @dev Supported Uniswap V3 Adapter address.
    address private immutable uniV3Adapter;
    /// @dev Supported Uniswap V2 Adapter address.
    address private immutable uniV2Adapter;
    /// @dev Supported Sushiswap Adapter address.
    address private immutable sushiAdapter;

    constructor(
        address _creditManager,
        address _uniV3Adapter,
        address _uniV2Adapter,
        address _sushiAdapter
    ) EIP712("LimitOrderBot", "1") {
        manager = ICreditManagerV2(_creditManager);
        uniV3Adapter = _uniV3Adapter;
        uniV2Adapter = _uniV2Adapter;
        sushiAdapter = _sushiAdapter;
    }

    /// @inheritdoc ILimitOrderBot
    function ORDER_TYPEHASH() external override pure returns (bytes32) {
        return _ORDER_TYPEHASH;
    }

    /// @inheritdoc ILimitOrderBot
    function DOMAIN_SEPARATOR() external override view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @inheritdoc ILimitOrderBot
    function nonces(address borrower) external override view returns (uint256) {
        return _nonces[borrower].current();
    }

    /// @inheritdoc ILimitOrderBot
    function executeOrder(
        MultiCall[] calldata calls,
        Order calldata order,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override {
        _validateSignature(order, v, r, s);
        _executeOrder(calls, order);
    }

    /// @inheritdoc ILimitOrderBot
    function bumpNonce() external override {
        _useNonce(msg.sender);
    }

    /// @dev Checks if signature is valid for a given order.
    function _validateSignature(
        Order calldata order,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal {
        bytes32 structHash = keccak256(
            abi.encode(
                _ORDER_TYPEHASH,
                order.borrower,
                order.tokenIn,
                order.tokenOut,
                order.amountIn,
                order.minPrice,
                order.triggerPrice,
                _useNonce(order.borrower)
            )
        );
        bytes32 typedDataHash = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(typedDataHash, v, r, s);
        if (signer != order.borrower)
            revert InvalidSignature();
    }

    /// @dev Validates an order and executes multicall with some checks that it
    ///      indeed performs the correct action and doesn't steal user's funds.
    function _executeOrder(MultiCall[] calldata calls, Order calldata order) internal {
        (
            address creditAccount,
            uint256 balanceBefore,
            uint256 amountIn,
            uint256 minAmountOut
        ) = _validateOrder(order);

        (
            address[] memory tokensSpent,
            uint256 numTokens
        ) = _validateCalls(calls, order.tokenIn);

        address facade = manager.creditFacade();
        ICreditFacade(facade).botMulticall(
            order.borrower,
            _prependCall(
                calls,
                _makeBalanceCheckCall(
                    facade,
                    tokensSpent,
                    numTokens,
                    order.tokenOut,
                    minAmountOut
                )
            )
        );

        uint256 balanceAfter = IERC20(order.tokenIn).balanceOf(creditAccount);
        if (balanceAfter + amountIn != balanceBefore)
            revert InvalidAmountSold();

        emit OrderExecuted(order.borrower, order.tokenIn, order.tokenOut, amountIn);
    }

    /// @dev Checks if order is correctly constructed and can be executed.
    ///      Returns borrower's credit account, its balance of tokenIn, actual
    ///      amount of tokenIn to sell and minimum amount of tokenOut to receive.
    function _validateOrder(Order calldata order)
        internal
        view
        returns (
            address creditAccount,
            uint256 balance,
            uint256 amountIn,
            uint256 minAmountOut
        )
    {
        if (order.tokenIn == order.tokenOut || order.amountIn == 0)
            revert InvalidOrder();

        uint256 ONE = 10 ** IERC20Metadata(order.tokenIn).decimals();
        if (order.triggerPrice > 0) {
            uint256 price = manager.priceOracle().convert(
                ONE, order.tokenIn, order.tokenOut
            );
            if (price > order.triggerPrice)
                revert NotTriggered();
        }

        creditAccount = manager.getCreditAccountOrRevert(order.borrower);
        balance = IERC20(order.tokenIn).balanceOf(creditAccount);
        if (balance <= 1)
            revert NothingToSell();

        amountIn = balance > order.amountIn ? order.amountIn : balance - 1;
        minAmountOut = amountIn * order.minPrice / ONE;
    }

    /// @dev Validates that multicall is correct, i.e. each call is to the
    ///      supported method of supported adapters.
    /// @dev Returns an array of tokens that are spent from credit account
    ///      besides the one that should be sold.
    function _validateCalls(
        MultiCall[] calldata calls,
        address tokenIn
    )
        internal
        view
        returns (
            address[] memory tokensSpent,
            uint256 numTokens
        )
    {
        uint256 numCalls = calls.length;
        tokensSpent = new address[](numCalls);
        numTokens = 0;
        for (uint256 i = 0; i < numCalls; ) {
            MultiCall calldata mcall = calls[i];
            unchecked {
                ++i;
            }

            address tokenSpent;
            if (mcall.target == manager.universalAdapter()) {
                tokenSpent = _validateUniversalAdapterCall(mcall.callData);
            } else if (mcall.target == uniV3Adapter) {
                tokenSpent = _validateUniV3AdapterCall(mcall.callData);
            } else if (mcall.target == uniV2Adapter || mcall.target == sushiAdapter) {
                tokenSpent = _validateUniV2AdapterCall(mcall.callData);
            } else {
                revert InvalidCallTarget();
            }
            if (tokenSpent == tokenIn) continue;

            uint256 j;
            for (j = 0; j < numTokens; ) {
                if (tokensSpent[j] == tokenSpent) break;
                unchecked {
                    ++j;
                }
            }
            if (j == numTokens) {
                tokensSpent[numTokens] = tokenSpent;
                unchecked {
                    ++numTokens;
                }
            }
        }
    }

    /// @dev Returns a balance check call that makes sure that account receives
    ///      at least the desired amount of token out and doesn't spend any of
    ///      the tokens it owns except the one that should be sold.
    function _makeBalanceCheckCall(
        address facade,
        address[] memory tokensSpent,
        uint256 numTokens,
        address tokenOut,
        uint256 minAmountOut
    )
        internal
        pure
        returns (MultiCall memory checkCall)
    {
        Balance[] memory balanceDeltas = new Balance[](numTokens + 1);
        for (uint256 i = 0; i < numTokens; ) {
            balanceDeltas[i] = Balance({token: tokensSpent[i], balance: 0});
            unchecked {
                ++i;
            }
        }
        balanceDeltas[numTokens] = Balance({token: tokenOut, balance: minAmountOut});
        checkCall = MultiCall({
            target: address(facade),
            callData: abi.encodeWithSelector(
                ICreditFacadeExtended.revertIfReceivedLessThan.selector,
                balanceDeltas
            )
        });
    }

    /// @dev Validates that call is made to withdrawTo method, returns withdrawn token.
    function _validateUniversalAdapterCall(bytes calldata callData)
        internal
        pure
        returns (address tokenSpent)
    {
        bytes4 selector = bytes4(callData);
        if (selector != IUniversalAdapter.withdrawTo.selector)
            revert InvalidCallMethod();
        (tokenSpent, , ) = abi.decode(callData[4:], (address,address,uint256));
    }

    /// @dev Validates that call is made to the supported Uni V3 method,
    ///      returns the token spent in the call.
    function _validateUniV3AdapterCall(bytes calldata callData)
        internal
        pure
        returns (address tokenSpent)
    {
        bytes4 selector = bytes4(callData);
        if (selector == IUniswapV3Adapter.exactAllInputSingle.selector) {
            IUniswapV3Adapter.ExactAllInputSingleParams memory params = abi.decode(
                callData[4:],
                (IUniswapV3Adapter.ExactAllInputSingleParams)
            );
            tokenSpent = params.tokenIn;
        } else if (selector == IUniswapV3Adapter.exactAllInput.selector) {
            IUniswapV3Adapter.ExactAllInputParams memory params = abi.decode(
                callData[4:],
                (IUniswapV3Adapter.ExactAllInputParams)
            );
            tokenSpent = _parseTokenIn(params.path);
        } else if (selector == ISwapRouter.exactInputSingle.selector) {
            ISwapRouter.ExactInputSingleParams memory params = abi.decode(
                callData[4:],
                (ISwapRouter.ExactInputSingleParams)
            );
            tokenSpent = params.tokenIn;
        } else if (selector == ISwapRouter.exactInput.selector) {
            ISwapRouter.ExactInputParams memory params = abi.decode(
                callData[4:],
                (ISwapRouter.ExactInputParams)
            );
            tokenSpent = _parseTokenIn(params.path);
        } else {
            revert InvalidCallMethod();
        }
    }

    /// @dev Validates that call is made to the supported Uni V2 method,
    ///      returns the token spent in the call.
    function _validateUniV2AdapterCall(bytes calldata callData)
        internal
        pure
        returns (address tokenSpent)
    {
        bytes4 selector = bytes4(callData);
        address[] memory path;
        if (selector == IUniswapV2Adapter.swapAllTokensForTokens.selector) {
            (, path, ) = abi.decode(
                callData[4:],
                (uint256, address[], uint256)
            );
        } else if (selector == IUniswapV2Router01.swapExactTokensForTokens.selector) {
            (, , path, , ) = abi.decode(
                callData[4:],
                (uint256, uint256, address[], address, uint256)
            );
        } else {
            revert InvalidCallMethod();
        }
        tokenSpent = path[0];
    }

    /// @dev Returns borrower's current nonce and then increments it.
    function _useNonce(address borrower) internal returns (uint256 current) {
        Counters.Counter storage nonce = _nonces[borrower];
        current = nonce.current();
        nonce.increment();
    }

    /// @dev Parses input token address from bytes-encoded Uniswap V3 swap path.
    function _parseTokenIn(bytes memory path) internal pure returns (address tokenIn) {
        assembly {
            tokenIn := div(
                mload(add(path, 0x20)),
                0x1000000000000000000000000
            )
        }
        return tokenIn;
    }

    /// @dev Prepends given call to the multicall.
    function _prependCall(MultiCall[] calldata calls, MultiCall memory call)
        internal
        pure
        returns (MultiCall[] memory newCalls)
    {
        uint256 numCalls = calls.length;
        newCalls = new MultiCall[](numCalls + 1);
        newCalls[0] = call;
        for (uint256 i = 0; i < numCalls; ) {
            newCalls[i + 1] = calls[i];
            unchecked {
                ++i;
            }
        }
    }
}
