// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {BoxHook} from "../src/BoxHook.sol";
import {Booster} from "../src/Booster.sol";
import {CardVault} from "../src/CardVault.sol";
import {CardOracle} from "../src/CardOracle.sol";

contract BoxHookTest is Test {
    uint160 constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );
    uint256 constant ETH_USD = 4000e6;

    PoolManager pm;
    PoolSwapTest router;
    PoolModifyLiquidityTest lpRouter;
    CardOracle oracle;
    CardVault vault;
    Booster packs;
    BoxHook hook;
    PoolKey key;

    address alice = makeAddr("alice");

    // shanks 2500, nami 12, nami 12 -> ev floor((2500+12+12)/3) = 841.333333 usd
    function setUp() public {
        uint16[] memory manifest = new uint16[](3);
        manifest[0] = 2;
        manifest[1] = 4;
        manifest[2] = 4;
        _deployAll(manifest, 0x4444);
    }

    function _deployAll(uint16[] memory manifest, uint160 namespace) internal {
        pm = new PoolManager(address(this));
        router = new PoolSwapTest(IPoolManager(address(pm)));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(pm)));
        oracle = new CardOracle();
        vault = new CardVault("http://localhost:5173/card/");
        packs = new Booster(oracle, vault);
        vault.setBooster(address(packs));

        uint16[] memory ids = new uint16[](2);
        uint256[] memory prices = new uint256[](2);
        ids[0] = 2;
        prices[0] = 2500e6;
        ids[1] = 4;
        prices[1] = 12e6;
        oracle.setPrices(ids, prices);
        oracle.setEthUsd(ETH_USD);

        address flags = address(FLAGS ^ (namespace << 144));
        deployCodeTo(
            "BoxHook.sol:BoxHook",
            abi.encode(IPoolManager(address(pm)), packs, uint256(11_500), uint256(9_000), address(this)),
            flags
        );
        hook = BoxHook(flags);

        packs.loadBox(manifest, address(hook));
        hook.depositInventory();

        key = PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(packs)), 0, 60, IHooks(hook));
        pm.initialize(key, Constants.SQRT_PRICE_1_1);

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        packs.approve(address(router), type(uint256).max);
    }

    function _buy(uint256 n) internal {
        uint256 cost = hook.quoteBuy(n);
        vm.prank(alice);
        router.swap{value: cost}(
            key,
            SwapParams({
                zeroForOne: true, // ETH (currency0) in, PACK (currency1) out
                amountSpecified: int256(n),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _sell(uint256 n) internal {
        vm.prank(alice);
        router.swap(
            key,
            SwapParams({
                zeroForOne: false, // PACK (currency1) in, ETH (currency0) out
                amountSpecified: -int256(n),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _usdToWei(uint256 usd6) internal pure returns (uint256) {
        return usd6 * 1e18 / ETH_USD;
    }

    function test_buyAtEvTimesPremium() public {
        uint256 ev = packs.evPerPack();
        assertEq(ev, uint256(2500e6 + 12e6 + 12e6) / 3);
        uint256 cost = hook.quoteBuy(1);
        assertEq(cost, _usdToWei(ev * 11_500 / 10_000));

        uint256 before = alice.balance;
        _buy(1);
        assertEq(before - alice.balance, cost);
        assertEq(packs.balanceOf(alice), 1);
        assertEq(hook.ethFloat(), cost);
        assertEq(hook.packInventory(), 2);
    }

    function test_sellBackAtBuyback() public {
        _buy(2);
        uint256 ev = packs.evPerPack();
        uint256 payout = hook.quoteSell(1);
        assertEq(payout, _usdToWei(ev * 9_000 / 10_000));

        uint256 before = alice.balance;
        _sell(1);
        assertEq(alice.balance - before, payout);
        assertEq(packs.balanceOf(alice), 1);
        assertEq(hook.packInventory(), 2);
    }

    function test_openRevealMintsCardAndShrinksBox() public {
        _buy(1);
        vm.startPrank(alice);
        packs.open(1);
        uint64 commitBlock = uint64(block.number);
        vm.roll(block.number + 1);
        vm.setBlockhash(commitBlock, keccak256("berrybox"));
        uint16[] memory cards = packs.reveal();
        vm.stopPrank();

        assertEq(cards.length, 1);
        assertEq(vault.balanceOf(alice), 1);
        assertEq(vault.cardIdOf(1), cards[0]);
        assertEq(packs.packsRemaining(), 2);
        assertEq(packs.totalSupply(), 2); // hook inventory only, invariant restored
    }

    function test_chasePullReprices() public {
        // fresh 2-card box: one chase, one common
        uint16[] memory manifest = new uint16[](2);
        manifest[0] = 2;
        manifest[1] = 4;
        _deployAll(manifest, 0x5555);

        uint256 costBefore = hook.quoteBuy(1);
        assertEq(costBefore, _usdToWei((uint256(2500e6 + 12e6) / 2) * 11_500 / 10_000));

        _buy(1);
        vm.startPrank(alice);
        packs.open(1);
        uint64 commitBlock = uint64(block.number);
        vm.roll(block.number + 1);
        bytes32 bh = keccak256("chase");
        vm.setBlockhash(commitBlock, bh);
        uint16[] memory cards = packs.reveal();
        vm.stopPrank();

        // same draw formula as the contract
        uint256 idx = uint256(keccak256(abi.encodePacked(bh, alice, uint256(0)))) % 2;
        assertEq(cards[0], manifest[idx]);

        uint16 leftover = cards[0] == 2 ? 4 : 2;
        uint256 evAfter = oracle.price(leftover);
        assertEq(packs.evPerPack(), evAfter);
        assertEq(hook.quoteBuy(1), _usdToWei(evAfter * 11_500 / 10_000));
        assertTrue(hook.quoteBuy(1) != costBefore);
    }

    function test_ethSpecifiedRejected() public {
        vm.prank(alice);
        vm.expectRevert();
        router.swap{value: 1 ether}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -1 ether, // exact-input ETH -> fractional packs, must revert
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_externalLiquidityRejected() public {
        vm.expectRevert();
        lpRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: 0}), ""
        );
    }

    function test_soldOutReverts() public {
        _buy(3);
        vm.expectRevert();
        hook.quoteBuy(1);
    }

    function test_withdrawHouseFloat() public {
        _buy(2);
        uint256 float_ = hook.ethFloat();
        address treasury = makeAddr("treasury");
        hook.withdraw(treasury, float_);
        assertEq(treasury.balance, float_);
        assertEq(hook.ethFloat(), 0);
    }
}
