// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import { Test } from "@forge-std/Test.sol";

import { LimitOrderBot } from "../src/LimitOrderBot.sol";
import { ILimitOrderBot, Order } from "../src/interfaces/ILimitOrderBot.sol";

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";

import { BotList } from "@gearbox-protocol/core-v2/contracts/support/BotList.sol";
import { MultiCall } from "@gearbox-protocol/core-v2/contracts/libraries/MultiCall.sol";
import { CreditFacade } from "@gearbox-protocol/core-v2/contracts/credit/CreditFacade.sol";
import { CreditManager } from "@gearbox-protocol/core-v2/contracts/credit/CreditManager.sol";
import { UniversalAdapter } from "@gearbox-protocol/core-v2/contracts/adapters/UniversalAdapter.sol";
import { UNIVERSAL_CONTRACT } from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";
import { IPriceOracleV2 } from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceOracle.sol";
import { ICreditFacadeExceptions } from "@gearbox-protocol/core-v2/contracts/interfaces/ICreditFacade.sol";
import { ICreditManagerV2Exceptions } from "@gearbox-protocol/core-v2/contracts/interfaces/ICreditManagerV2.sol";

import { IQuoter } from "@gearbox-protocol/integrations-v2/contracts/integrations/uniswap/IQuoter.sol";
import { ISwapRouter } from "@gearbox-protocol/integrations-v2/contracts/integrations/uniswap/IUniswapV3.sol";
import { IUniswapV3Adapter } from "@gearbox-protocol/integrations-v2/contracts/interfaces/uniswap/IUniswapV3Adapter.sol";
import { IUniswapV2Adapter } from "@gearbox-protocol/integrations-v2/contracts/interfaces/uniswap/IUniswapV2Adapter.sol";
import { IUniswapV2Router01 } from "@gearbox-protocol/integrations-v2/contracts/integrations/uniswap/IUniswapV2Router01.sol";


contract LimitOrderBotTest is Test {
    LimitOrderBot private bot;
    BotList private botList;
    CreditFacade private facade;
    CreditManager private manager;
    UniversalAdapter private universalAdapter;

    IQuoter private constant quoter = IQuoter(0xb27308f9F90D607463bb33eA1BeBb41C27CE5AB6);

    address private constant ADDRESS_PROVIDER = 0xcF64698AFF7E5f27A11dff868AF228653ba53be0;
    address private constant CREDIT_MANAGER = 0x5887ad4Cb2352E7F01527035fAa3AE0Ef2cE2b9B;
    address private constant UNISWAP_V3_ADAPTER = 0xed5B30F8604c0743F167a19F42fEC8d284963a7D;
    address private constant UNISWAP_V2_ADAPTER = 0x2Df86Ae03c2e3753dCb1FeA070822e631d5F2f21;
    address private constant SUSHISWAP_ADAPTER = 0xc4d1A095007C12E1De709ee838dFDBeBe9cF7801;

    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    address private constant USER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address private constant OTHER_USER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    uint256 private constant USER_PRIVATE_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    event OrderExecuted(
        address indexed borrower,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn
    );

    function setUp() public {
        manager = CreditManager(CREDIT_MANAGER);

        facade = new CreditFacade(CREDIT_MANAGER, address(0), address(0), false);
        universalAdapter = new UniversalAdapter(CREDIT_MANAGER);

        vm.startPrank(manager.creditConfigurator());
        facade.setLimitPerBlock(type(uint128).max);
        facade.setCreditAccountLimits(0, type(uint128).max);
        manager.upgradeCreditFacade(address(facade));
        manager.changeContractAllowance(address(universalAdapter), UNIVERSAL_CONTRACT);
        vm.stopPrank();

        bot = new LimitOrderBot(
            CREDIT_MANAGER,
            UNISWAP_V3_ADAPTER,
            UNISWAP_V2_ADAPTER,
            SUSHISWAP_ADAPTER
        );

        botList = new BotList(ADDRESS_PROVIDER);
        vm.prank(manager.creditConfigurator());
        facade.setBotList(address(botList));
    }

    ///
    /// SIGNATURE-RELATED TESTS
    ///

    function test_bumpNonce_increments_nonce() public {
        uint256 currentNonce = bot.nonces(USER);
        vm.prank(USER);
        bot.bumpNonce();
        assertEq(bot.nonces(USER), currentNonce + 1);
    }

    function test_executeOrder_reverts_on_wrong_signer() public {
        Order memory order = _createTestOrder();
        order.borrower = OTHER_USER;

        (uint8 v, bytes32 r, bytes32 s) = _signOrder(
            USER_PRIVATE_KEY, order, bot.nonces(OTHER_USER)
        );

        MultiCall[] memory calls;

        vm.expectRevert(ILimitOrderBot.InvalidSignature.selector);
        bot.executeOrder(calls, order, v, r, s);
    }

    function test_executeOrder_reverts_on_wrong_nonce() public {
        Order memory order = _createTestOrder();

        (uint8 v, bytes32 r, bytes32 s) = _signOrder(
            USER_PRIVATE_KEY, order, bot.nonces(USER)
        );

        vm.prank(USER);
        bot.bumpNonce();

        MultiCall[] memory calls;

        vm.expectRevert(ILimitOrderBot.InvalidSignature.selector);
        bot.executeOrder(calls, order, v, r, s);
    }

    function test_executeOrder_reverts_on_wrong_bot() public {
        Order memory order = _createTestOrder();

        (uint8 v, bytes32 r, bytes32 s) = _signOrder(
            USER_PRIVATE_KEY, order, bot.nonces(USER)
        );

        MultiCall[] memory calls;

        LimitOrderBot otherBot = new LimitOrderBot(
            CREDIT_MANAGER,
            UNISWAP_V3_ADAPTER,
            UNISWAP_V2_ADAPTER,
            SUSHISWAP_ADAPTER
        );

        vm.expectRevert(ILimitOrderBot.InvalidSignature.selector);
        otherBot.executeOrder(calls, order, v, r, s);
    }

    ///
    /// ORDER-RELATED TESTS
    ///

    function test_executeOrder_reverts_on_invalid_order() public {
        Order memory order = _createTestOrder();
        order.tokenOut = order.tokenIn;

        (uint8 v, bytes32 r, bytes32 s) = _signOrder(
            USER_PRIVATE_KEY, order, bot.nonces(USER)
        );

        MultiCall[] memory calls;

        vm.expectRevert(ILimitOrderBot.InvalidOrder.selector);
        bot.executeOrder(calls, order, v, r, s);
    }

    function test_executeOrder_reverts_on_unsatisfied_trigger() public {
        Order memory order = _createTestOrder();
        order.triggerPrice = _oraclePrice(DAI, WETH) * 8 / 10;

        (uint8 v, bytes32 r, bytes32 s) = _signOrder(
            USER_PRIVATE_KEY, order, bot.nonces(USER)
        );

        MultiCall[] memory calls;

        vm.expectRevert(ILimitOrderBot.NotTriggered.selector);
        bot.executeOrder(calls, order, v, r, s);
    }

    function test_executeOrder_reverts_on_user_without_account() public {
        Order memory order = _createTestOrder();

        (uint8 v, bytes32 r, bytes32 s) = _signOrder(
            USER_PRIVATE_KEY, order, bot.nonces(USER)
        );

        MultiCall[] memory calls;

        vm.expectRevert(ICreditManagerV2Exceptions.HasNoOpenedAccountException.selector);
        bot.executeOrder(calls, order, v, r, s);
    }

    function test_executeOrder_reverts_on_user_without_balance() public {
        _createTestAccount(USER);

        Order memory order = _createTestOrder();
        order.tokenIn = WBTC;

        (uint8 v, bytes32 r, bytes32 s) = _signOrder(
            USER_PRIVATE_KEY, order, bot.nonces(USER)
        );

        MultiCall[] memory calls;

        vm.expectRevert(ILimitOrderBot.NothingToSell.selector);
        bot.executeOrder(calls, order, v, r, s);
    }

    ///
    /// MULTICALL-RELATED TESTS
    ///

    function test_executeOrder_reverts_on_invalid_call_target() public {
        _createTestAccount(USER);

        Order memory order = _createTestOrder();

        (uint8 v, bytes32 r, bytes32 s) = _signOrder(
            USER_PRIVATE_KEY, order, bot.nonces(USER)
        );

        MultiCall[] memory calls = new MultiCall[](1);
        calls[0] = MultiCall({
            target: address(0),
            callData: bytes("dummy calldata")
        });
        vm.expectRevert(ILimitOrderBot.InvalidCallTarget.selector);
        bot.executeOrder(calls, order, v, r, s);
    }

    function test_executeOrder_reverts_on_invalid_call_method() public {
        _createTestAccount(USER);

        Order memory order = _createTestOrder();

        (uint8 v, bytes32 r, bytes32 s) = _signOrder(
            USER_PRIVATE_KEY, order, bot.nonces(USER)
        );

        MultiCall[] memory calls = new MultiCall[](1);

        calls[0] = MultiCall({
            target: UNISWAP_V3_ADAPTER,
            callData: bytes("dummy calldata")
        });
        vm.expectRevert(ILimitOrderBot.InvalidCallMethod.selector);
        bot.executeOrder(calls, order, v, r, s);

        calls[0] = MultiCall({
            target: UNISWAP_V2_ADAPTER,
            callData: bytes("dummy calldata")
        });
        vm.expectRevert(ILimitOrderBot.InvalidCallMethod.selector);
        bot.executeOrder(calls, order, v, r, s);

        calls[0] = MultiCall({
            target: SUSHISWAP_ADAPTER,
            callData: bytes("dummy calldata")
        });
        vm.expectRevert(ILimitOrderBot.InvalidCallMethod.selector);
        bot.executeOrder(calls, order, v, r, s);

        calls[0] = MultiCall({
            target: address(universalAdapter),
            callData: bytes("dummy calldata")
        });
        vm.expectRevert(ILimitOrderBot.InvalidCallMethod.selector);
        bot.executeOrder(calls, order, v, r, s);
    }

    ///
    /// BALANCE-RELATED TESTS
    ///

    function test_executeOrder_reverts_on_spending_side_tokens() public {
        _createTestAccount(USER);

        Order memory order = _createTestOrder();

        (uint8 v, bytes32 r, bytes32 s) = _signOrder(
            USER_PRIVATE_KEY, order, bot.nonces(USER)
        );

        MultiCall[] memory calls = new MultiCall[](2);
        calls[0] = MultiCall({
            target: UNISWAP_V3_ADAPTER,
            callData: abi.encodeWithSelector(
                ISwapRouter.exactInput.selector,
                ISwapRouter.ExactInputParams({
                    path: abi.encodePacked(DAI, uint24(100), USDC),
                    recipient: address(0),
                    deadline: block.timestamp,
                    amountIn: order.amountIn,
                    amountOutMinimum: 0
                })
            )
        });
        calls[1] = MultiCall({
            target: UNISWAP_V3_ADAPTER,
            callData: abi.encodeWithSelector(
                IUniswapV3Adapter.exactAllInput.selector,
                IUniswapV3Adapter.ExactAllInputParams({
                    path: abi.encodePacked(USDC, uint24(500), WETH),
                    deadline: block.timestamp,
                    rateMinRAY: 0
                })
            )
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                ICreditFacadeExceptions.BalanceLessThanMinimumDesiredException.selector,
                USDC
            )
        );
        bot.executeOrder(calls, order, v, r, s);
    }

    function test_executeOrder_reverts_on_selling_below_min_price() public {
        _createTestAccount(USER);

        Order memory order = _createTestOrder();
        order.minPrice = _oraclePrice(DAI, WETH) * 12 / 10;

        (uint8 v, bytes32 r, bytes32 s) = _signOrder(
            USER_PRIVATE_KEY, order, bot.nonces(USER)
        );

        MultiCall[] memory calls = new MultiCall[](1);
        calls[0] = MultiCall({
            target: UNISWAP_V3_ADAPTER,
            callData: abi.encodeWithSelector(
                ISwapRouter.exactInput.selector,
                ISwapRouter.ExactInputParams({
                    path: abi.encodePacked(DAI, uint24(100), USDC, uint24(500), WETH),
                    recipient: address(0),
                    deadline: block.timestamp,
                    amountIn: order.amountIn,
                    amountOutMinimum: 0
                })
            )
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                ICreditFacadeExceptions.BalanceLessThanMinimumDesiredException.selector,
                WETH
            )
        );
        bot.executeOrder(calls, order, v, r, s);
    }

    function test_executeOrder_reverts_on_selling_more_than_required() public {
        _createTestAccount(USER);

        Order memory order = _createTestOrder();

        (uint8 v, bytes32 r, bytes32 s) = _signOrder(
            USER_PRIVATE_KEY, order, bot.nonces(USER)
        );

        MultiCall[] memory calls = new MultiCall[](1);
        calls[0] = MultiCall({
            target: UNISWAP_V3_ADAPTER,
            callData: abi.encodeWithSelector(
                ISwapRouter.exactInput.selector,
                ISwapRouter.ExactInputParams({
                    path: abi.encodePacked(DAI, uint24(100), USDC, uint24(500), WETH),
                    recipient: address(0),
                    deadline: block.timestamp,
                    amountIn: order.amountIn * 11 / 10,
                    amountOutMinimum: 0
                })
            )
        });

        vm.expectRevert(ILimitOrderBot.InvalidAmountSold.selector);
        bot.executeOrder(calls, order, v, r, s);
    }

    function test_executeOrder_reverts_on_selling_less_than_required() public {
        _createTestAccount(USER);

        Order memory order = _createTestOrder();

        (uint8 v, bytes32 r, bytes32 s) = _signOrder(
            USER_PRIVATE_KEY, order, bot.nonces(USER)
        );

        MultiCall[] memory calls = new MultiCall[](1);
        calls[0] = MultiCall({
            target: UNISWAP_V3_ADAPTER,
            callData: abi.encodeWithSelector(
                ISwapRouter.exactInput.selector,
                ISwapRouter.ExactInputParams({
                    path: abi.encodePacked(DAI, uint24(100), USDC, uint24(500), WETH),
                    recipient: address(0),
                    deadline: block.timestamp,
                    amountIn: order.amountIn * 9 / 10,
                    amountOutMinimum: 0
                })
            )
        });

        vm.expectRevert(ILimitOrderBot.InvalidAmountSold.selector);
        bot.executeOrder(calls, order, v, r, s);
    }

    ///
    /// SUCCESSFUL EXECUTION TESTS
    ///

    function test_executeOrder_works_currectly() public {
        (
            address account,
            uint256 usdcBefore,
            uint256 daiBefore
        ) = _createTestAccount(USER);

        Order memory order = _createTestOrder();

        uint256 nonce = bot.nonces(USER);
        (uint8 v, bytes32 r, bytes32 s) = _signOrder(
            USER_PRIVATE_KEY, order, nonce
        );

        uint256 minWethAmountOut = order.amountIn * order.minPrice / 1 ether;

        MultiCall[] memory calls = new MultiCall[](1);
        calls[0] = MultiCall({
            target: UNISWAP_V3_ADAPTER,
            callData: abi.encodeWithSelector(
                ISwapRouter.exactInput.selector,
                ISwapRouter.ExactInputParams({
                    path: abi.encodePacked(
                        DAI, uint24(100), USDC, uint24(500), WETH
                    ),
                    recipient: address(0),
                    deadline: block.timestamp,
                    amountIn: order.amountIn,
                    amountOutMinimum: 0
                })
            )
        });

        vm.expectEmit(true, true, true, true);
        emit OrderExecuted(USER, DAI, WETH, order.amountIn);

        bot.executeOrder(calls, order, v, r, s);

        assertEq(bot.nonces(USER), nonce + 1);
        assertGe(IERC20(WETH).balanceOf(account), minWethAmountOut);
        assertGe(IERC20(USDC).balanceOf(account), usdcBefore);
        assertEq(IERC20(DAI).balanceOf(account) + order.amountIn, daiBefore);
    }

    function test_executeOrder_works_correctly_with_trigger_price_set() public {
        (
            address account,
            uint256 usdcBefore,
            uint256 daiBefore
        ) = _createTestAccount(USER);

        Order memory order = _createTestOrder();
        order.triggerPrice = _oraclePrice(DAI, WETH) * 12 / 10;

        (uint8 v, bytes32 r, bytes32 s) = _signOrder(
            USER_PRIVATE_KEY, order, bot.nonces(USER)
        );

        uint256 minWethAmountOut = order.amountIn * order.minPrice / 1 ether;

        MultiCall[] memory calls = new MultiCall[](1);
        calls[0] = MultiCall({
            target: UNISWAP_V3_ADAPTER,
            callData: abi.encodeWithSelector(
                ISwapRouter.exactInput.selector,
                ISwapRouter.ExactInputParams({
                    path: abi.encodePacked(
                        DAI, uint24(100), USDC, uint24(500), WETH
                    ),
                    recipient: address(0),
                    deadline: block.timestamp,
                    amountIn: order.amountIn,
                    amountOutMinimum: 0
                })
            )
        });

        vm.expectEmit(true, true, true, true);
        emit OrderExecuted(USER, DAI, WETH, order.amountIn);

        bot.executeOrder(calls, order, v, r, s);

        assertGe(IERC20(WETH).balanceOf(account), minWethAmountOut);
        assertGe(IERC20(USDC).balanceOf(account), usdcBefore);
        assertEq(IERC20(DAI).balanceOf(account) + order.amountIn, daiBefore);
    }

    function test_executeOrder_works_correctly_with_order_size_larger_than_balance() public {
        (
            address account,
            uint256 usdcBefore,
            uint256 daiBefore
        ) = _createTestAccount(USER);

        Order memory order = _createTestOrder();
        order.amountIn = 2 * daiBefore;

        (uint8 v, bytes32 r, bytes32 s) = _signOrder(
            USER_PRIVATE_KEY, order, bot.nonces(USER)
        );

        uint256 amountIn = daiBefore - 1;
        uint256 minWethAmountOut = amountIn * order.minPrice / 1 ether;

        MultiCall[] memory calls = new MultiCall[](1);
        calls[0] = MultiCall({
            target: UNISWAP_V3_ADAPTER,
            callData: abi.encodeWithSelector(
                ISwapRouter.exactInput.selector,
                ISwapRouter.ExactInputParams({
                    path: abi.encodePacked(
                        DAI, uint24(100), USDC, uint24(500), WETH
                    ),
                    recipient: address(0),
                    deadline: block.timestamp,
                    amountIn: amountIn,
                    amountOutMinimum: 0
                })
            )
        });

        vm.expectEmit(true, true, true, true);
        emit OrderExecuted(USER, DAI, WETH, amountIn);

        bot.executeOrder(calls, order, v, r, s);

        assertGe(IERC20(WETH).balanceOf(account), minWethAmountOut);
        assertGe(IERC20(USDC).balanceOf(account), usdcBefore);
        assertEq(IERC20(DAI).balanceOf(account) + amountIn, daiBefore);
    }

    function test_executeOrder_works_correctly_with_bounty_withdraw_call() public {
        (
            address account,
            uint256 usdcBefore,
            uint256 daiBefore
        ) = _createTestAccount(USER);

        Order memory order = _createTestOrder();

        (uint8 v, bytes32 r, bytes32 s) = _signOrder(
            USER_PRIVATE_KEY, order, bot.nonces(USER)
        );

        uint256 minWethAmountOut = order.amountIn * order.minPrice / 1 ether;
        bytes memory swapPath = abi.encodePacked(
            DAI, uint24(100), USDC, uint24(500), WETH
        );
        uint256 bounty = quoter.quoteExactInput(swapPath, order.amountIn) - minWethAmountOut;

        MultiCall[] memory calls = new MultiCall[](2);
        calls[0] = MultiCall({
            target: UNISWAP_V3_ADAPTER,
            callData: abi.encodeWithSelector(
                ISwapRouter.exactInput.selector,
                ISwapRouter.ExactInputParams({
                    path: swapPath,
                    recipient: address(0),
                    deadline: block.timestamp,
                    amountIn: order.amountIn,
                    amountOutMinimum: 0
                })
            )
        });
        calls[1] = MultiCall({
            target: address(universalAdapter),
            callData: abi.encodeWithSelector(
                UniversalAdapter.withdrawTo.selector,
                WETH,
                address(this),
                bounty
            )
        });

        vm.expectEmit(true, true, true, true);
        emit OrderExecuted(USER, DAI, WETH, order.amountIn);

        bot.executeOrder(calls, order, v, r, s);

        assertGe(IERC20(WETH).balanceOf(account), minWethAmountOut);
        assertGe(IERC20(USDC).balanceOf(account), usdcBefore);
        assertEq(IERC20(DAI).balanceOf(account) + order.amountIn, daiBefore);
        assertEq(IERC20(WETH).balanceOf(address(this)), bounty);
    }

    function test_executeOrder_works_correctly_with_calls_involving_side_tokens() public {
        (
            address account,
            uint256 usdcBefore,
            uint256 daiBefore
        ) = _createTestAccount(USER);

        Order memory order = _createTestOrder();

        (uint8 v, bytes32 r, bytes32 s) = _signOrder(
            USER_PRIVATE_KEY, order, bot.nonces(USER)
        );

        uint256 minWethAmountOut = order.amountIn * order.minPrice / 1 ether;
        uint256 usdcOut = quoter.quoteExactInputSingle(
            DAI, USDC, 100, order.amountIn, 0
        );
        address[] memory path = new address[](2);
        (path[0], path[1]) = (USDC, WETH);

        MultiCall[] memory calls = new MultiCall[](2);
        calls[0] = MultiCall({
            target: UNISWAP_V3_ADAPTER,
            callData: abi.encodeWithSelector(
                ISwapRouter.exactInputSingle.selector,
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: DAI,
                    tokenOut: USDC,
                    fee: 100,
                    recipient: address(0),
                    deadline: block.timestamp,
                    amountIn: order.amountIn,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            )
        });
        calls[1] = MultiCall({
            target: SUSHISWAP_ADAPTER,
            callData: abi.encodeWithSelector(
                IUniswapV2Router01.swapExactTokensForTokens.selector,
                usdcOut,
                0,
                path,
                address(0),
                block.timestamp
            )
        });

        vm.expectEmit(true, true, true, true);
        emit OrderExecuted(USER, DAI, WETH, order.amountIn);

        bot.executeOrder(calls, order, v, r, s);

        assertGe(IERC20(WETH).balanceOf(account), minWethAmountOut);
        assertGe(IERC20(USDC).balanceOf(account), usdcBefore);
        assertEq(IERC20(DAI).balanceOf(account) + order.amountIn, daiBefore);
    }

    ///
    /// HELPERS
    ///

    /// @dev Opens an account for the user with 50K USDC collateral and 100 WETH
    ///      borrowed and swapped into DAI.
    function _createTestAccount(address user)
        internal
        returns (
            address account,
            uint256 usdcBalance,
            uint256 daiBalance
        )
    {
        uint256 wethAmount = 100 ether;
        usdcBalance = 50_000 * 10**6;

        MultiCall[] memory calls = new MultiCall[](2);
        calls[0] = MultiCall({
            target: address(facade),
            callData: abi.encodeWithSelector(
                CreditFacade.addCollateral.selector,
                user,
                USDC,
                usdcBalance
            )
        });
        calls[1] = MultiCall({
            target: UNISWAP_V3_ADAPTER,
            callData: abi.encodeWithSelector(
                IUniswapV3Adapter.exactAllInputSingle.selector,
                IUniswapV3Adapter.ExactAllInputSingleParams({
                    tokenIn: WETH,
                    tokenOut: DAI,
                    fee: 500,
                    deadline: block.timestamp,
                    rateMinRAY: 0,
                    sqrtPriceLimitX96: 0
                })
            )
        });

        deal(USDC, user, usdcBalance);
        vm.startPrank(user);
        IERC20(USDC).approve(CREDIT_MANAGER, usdcBalance);
        facade.openCreditAccountMulticall(wethAmount, user, calls, 0);
        botList.setBotStatus(address(bot), true);
        vm.stopPrank();

        account = manager.getCreditAccountOrRevert(user);
        daiBalance = IERC20(DAI).balanceOf(account);
    }

    /// @dev Creates a limit order to sell 50K of DAI for WETH with minPrice
    ///      20% below the current oracle price and no trigger price.
    function _createTestOrder() internal view returns (Order memory order) {
        order = Order({
            borrower: USER,
            tokenIn: DAI,
            tokenOut: WETH,
            amountIn: 50_000 ether,
            minPrice: _oraclePrice(DAI, WETH) * 8 / 10,
            triggerPrice: 0
        });
    }

    /// @dev Signs a limit order with a given signing key and returns the signature.
    function _signOrder(uint256 signingKey, Order memory order, uint256 nonce)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                bot.ORDER_TYPEHASH(),
                order.borrower,
                order.tokenIn,
                order.tokenOut,
                order.amountIn,
                order.minPrice,
                order.triggerPrice,
                nonce
            )
        );
        bytes32 typedDataHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                bot.DOMAIN_SEPARATOR(),
                structHash
            )
        );
        (v, r, s) = vm.sign(signingKey, typedDataHash);
    }

    /// @dev Returns oracle price of one unit of tokenIn in units of tokenOut.
    function _oraclePrice(address tokenIn, address tokenOut)
        internal
        view
        returns (uint256)
    {
        uint256 ONE = 10 ** IERC20Metadata(tokenIn).decimals();
        return manager.priceOracle().convert(ONE, tokenIn, tokenOut);
    }
}
