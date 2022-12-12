// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import { Test } from "@forge-std/Test.sol";

import { LimitOrderBot } from "../src/LimitOrderBot.sol";
import { ILimitOrderBot, Order } from "../src/interfaces/ILimitOrderBot.sol";

import { BotList } from "@gearbox-protocol/core-v2/contracts/support/BotList.sol";
import { MultiCall } from "@gearbox-protocol/core-v2/contracts/libraries/MultiCall.sol";
import { CreditFacade } from "@gearbox-protocol/core-v2/contracts/credit/CreditFacade.sol";
import { CreditManager } from "@gearbox-protocol/core-v2/contracts/credit/CreditManager.sol";
import { UniversalAdapter } from "@gearbox-protocol/core-v2/contracts/adapters/UniversalAdapter.sol";

import { UNIVERSAL_CONTRACT } from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { IPriceOracleV2 } from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceOracle.sol";
import { ICreditManagerV2Exceptions } from "@gearbox-protocol/core-v2/contracts/interfaces/ICreditManagerV2.sol";
import { ICreditFacadeExceptions } from "@gearbox-protocol/core-v2/contracts/interfaces/ICreditFacade.sol";

import { IUniswapV2Adapter } from "@gearbox-protocol/integrations-v2/contracts/interfaces/uniswap/IUniswapV2Adapter.sol";
import { IUniswapV3Adapter } from "@gearbox-protocol/integrations-v2/contracts/interfaces/uniswap/IUniswapV3Adapter.sol";
import { IUniswapV2Router01 } from "@gearbox-protocol/integrations-v2/contracts/integrations/uniswap/IUniswapV2Router01.sol";
import { ISwapRouter } from "@gearbox-protocol/integrations-v2/contracts/integrations/uniswap/IUniswapV3.sol";


contract LimitOrderBotTest is Test {
    LimitOrderBot private bot;

    BotList private botList;
    CreditFacade private facade;
    CreditManager private manager;

    UniversalAdapter private universalAdapter;

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
        Order memory order = Order({
            borrower: OTHER_USER,
            tokenIn: WETH,
            tokenOut: DAI,
            amountIn: 10 ether,
            minPrice: 1500 ether,
            triggerPrice: 0
        });

        (uint8 v, bytes32 r, bytes32 s) = _signOrder(
            USER_PRIVATE_KEY, order, bot.nonces(OTHER_USER)
        );

        MultiCall[] memory calls;

        vm.expectRevert(ILimitOrderBot.InvalidSignature.selector);
        bot.executeOrder(calls, order, v, r, s);
    }

    function test_executeOrder_reverts_on_wrong_nonce() public {
        Order memory order = Order({
            borrower: USER,
            tokenIn: WETH,
            tokenOut: DAI,
            amountIn: 10 ether,
            minPrice: 1500 ether,
            triggerPrice: 0
        });

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
        Order memory order = Order({
            borrower: USER,
            tokenIn: WETH,
            tokenOut: DAI,
            amountIn: 10 ether,
            minPrice: 1500 ether,
            triggerPrice: 0
        });

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

    function test_executeOrder_reverts_on_incorrect_order() public {
        Order memory order = Order({
            borrower: USER,
            tokenIn: DAI,
            tokenOut: DAI,
            amountIn: 10_000 ether,
            minPrice: 1 ether,
            triggerPrice: 0
        });

        (uint8 v, bytes32 r, bytes32 s) = _signOrder(
            USER_PRIVATE_KEY, order, bot.nonces(USER)
        );

        MultiCall[] memory calls;

        vm.expectRevert(ILimitOrderBot.InvalidOrder.selector);
        bot.executeOrder(calls, order, v, r, s);
    }

    function test_executeOrder_reverts_on_unsatisfied_trigger_condition() public {
        uint256 price = manager.priceOracle().convert(1 ether, DAI, WETH);
        Order memory order = Order({
            borrower: USER,
            tokenIn: DAI,
            tokenOut: WETH,
            amountIn: 10_000 ether,
            minPrice: price * 17 / 20,
            triggerPrice: price * 9 / 10
        });

        (uint8 v, bytes32 r, bytes32 s) = _signOrder(
            USER_PRIVATE_KEY, order, bot.nonces(USER)
        );

        MultiCall[] memory calls;

        vm.expectRevert(ILimitOrderBot.NotTriggered.selector);
        bot.executeOrder(calls, order, v, r, s);
    }

    function test_executeOrder_reverts_on_user_without_account() public {
        Order memory order = Order({
            borrower: USER,
            tokenIn: WETH,
            tokenOut: DAI,
            amountIn: 10 ether,
            minPrice: 1500 ether,
            triggerPrice: 0
        });

        (uint8 v, bytes32 r, bytes32 s) = _signOrder(
            USER_PRIVATE_KEY, order, bot.nonces(USER)
        );

        MultiCall[] memory calls;

        vm.expectRevert(ICreditManagerV2Exceptions.HasNoOpenedAccountException.selector);
        bot.executeOrder(calls, order, v, r, s);
    }

    function test_executeOrder_reverts_on_user_without_balance() public {
        _setUpAccount(USER);

        Order memory order = Order({
            borrower: USER,
            tokenIn: WBTC,
            tokenOut: DAI,
            amountIn: 1 * 10**8,
            minPrice: 0,
            triggerPrice: 0
        });

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

    function test_executeOrder_revers_on_invalid_call_target() public {
        _setUpAccount(USER);

        Order memory order = Order({
            borrower: USER,
            tokenIn: DAI,
            tokenOut: WETH,
            amountIn: 50_000 ether,
            minPrice: manager.priceOracle().convert(1 ether, DAI, WETH) * 9 / 10,
            triggerPrice: 0
        });

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
        _setUpAccount(USER);

        Order memory order = Order({
            borrower: USER,
            tokenIn: DAI,
            tokenOut: WETH,
            amountIn: 50_000 ether,
            minPrice: manager.priceOracle().convert(1 ether, DAI, WETH) * 9 / 10,
            triggerPrice: 0
        });

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
        _setUpAccount(USER);

        Order memory order = Order({
            borrower: USER,
            tokenIn: DAI,
            tokenOut: WETH,
            amountIn: 50_000 ether,
            minPrice: manager.priceOracle().convert(1 ether, DAI, WETH) * 9 / 10,
            triggerPrice: 0
        });

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
                    amountIn: 50_000 ether,
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
        _setUpAccount(USER);

        Order memory order = Order({
            borrower: USER,
            tokenIn: DAI,
            tokenOut: WETH,
            amountIn: 50_000 ether,
            minPrice: manager.priceOracle().convert(1 ether, DAI, WETH) * 12 / 10,
            triggerPrice: 0
        });

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
                    amountIn: 50_000 ether,
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
        _setUpAccount(USER);

        Order memory order = Order({
            borrower: USER,
            tokenIn: DAI,
            tokenOut: WETH,
            amountIn: 50_000 ether,
            minPrice: manager.priceOracle().convert(1 ether, DAI, WETH) * 9 / 10,
            triggerPrice: 0
        });

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
                    amountIn: 60_000 ether,
                    amountOutMinimum: 0
                })
            )
        });

        vm.expectRevert(ILimitOrderBot.InvalidAmountSold.selector);
        bot.executeOrder(calls, order, v, r, s);
    }

    function test_executeOrder_reverts_on_selling_less_than_required() public {
        _setUpAccount(USER);

        Order memory order = Order({
            borrower: USER,
            tokenIn: DAI,
            tokenOut: WETH,
            amountIn: 50_000 ether,
            minPrice: manager.priceOracle().convert(1 ether, DAI, WETH) * 7 / 10,
            triggerPrice: 0
        });

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
                    amountIn: 40_000 ether,
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

    // at least one test with no trigger
    // at least one test with trigger
    // include bounty payment

    ///
    /// HELPERS
    ///

    function _signOrder(
        uint256 signingKey,
        Order memory order,
        uint256 nonce
    )
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

    function _setUpAccount(address user) internal {
        deal(USDC, user, 50_000 * 10**6);

        MultiCall[] memory calls = new MultiCall[](2);
        calls[0] = MultiCall({
            target: address(facade),
            callData: abi.encodeWithSelector(
                CreditFacade.addCollateral.selector,
                user,
                USDC,
                50_000 * 10**6
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

        vm.startPrank(user);
        IERC20(USDC).approve(CREDIT_MANAGER, 50_000 * 10**6);
        facade.openCreditAccountMulticall(100 ether, user, calls, 0);
        botList.setBotStatus(address(bot), true);
        vm.stopPrank();
    }
}
