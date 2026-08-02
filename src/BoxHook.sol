// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import {Owned} from "solmate/src/auth/Owned.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

import {Booster} from "./Booster.sol";

/// @notice Custom-curve v4 hook that sells and buys back sealed packs at the expected
/// value of the remaining box contents. The hook is the sole counterparty: it holds the
/// unsold pack inventory and the USDC float as ERC-6909 claims on the PoolManager, and
/// the pool has no LP liquidity.
///
/// Supported swaps (PACK must always be the specified currency, whole packs only):
///  - exact-output PACK for USDC: buy packs at EV * premiumBps
///  - exact-input PACK for USDC: sell packs back at EV * buybackBps
contract BoxHook is BaseHook, IUnlockCallback, Owned {
    using CurrencySettler for Currency;
    using CurrencyLibrary for Currency;
    using SafeCast for uint256;

    Booster public immutable packs;
    ERC20 public immutable usdc;
    uint256 public immutable premiumBps;
    uint256 public immutable buybackBps;

    PoolKey public poolKey;

    uint8 constant DEPOSIT = 0;
    uint8 constant WITHDRAW = 1;

    event PacksBought(address indexed sender, uint256 count, uint256 cost);
    event PacksSold(address indexed sender, uint256 count, uint256 payout);

    error WrongPoolCurrencies();
    error PackMustBeSpecified();
    error OracleUnpriced();
    error SoldOut();
    error NoBuybackFloat();
    error NoExternalLiquidity();

    constructor(
        IPoolManager _poolManager,
        Booster _packs,
        ERC20 _usdc,
        uint256 _premiumBps,
        uint256 _buybackBps,
        address _owner
    ) BaseHook(_poolManager) Owned(_owner) {
        packs = _packs;
        usdc = _usdc;
        premiumBps = _premiumBps;
        buybackBps = _buybackBps;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        bool valid = (c0 == address(packs) && c1 == address(usdc)) || (c0 == address(usdc) && c1 == address(packs));
        if (!valid) revert WrongPoolCurrencies();
        poolKey = key;
        return BaseHook.beforeInitialize.selector;
    }

    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert NoExternalLiquidity();
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        bool exactInput = params.amountSpecified < 0;
        (Currency specified, Currency unspecified) =
            (params.zeroForOne == exactInput) ? (key.currency0, key.currency1) : (key.currency1, key.currency0);

        // The pack side must be the user-specified amount so packs stay whole-numbered.
        if (Currency.unwrap(specified) != address(packs)) revert PackMustBeSpecified();

        uint256 packCount = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        BeforeSwapDelta returnDelta;

        if (!exactInput) {
            // Buy: credit the swapper's USDC to the hook as claims, pay packs from claim inventory.
            uint256 cost = quoteBuy(packCount);
            unspecified.take(poolManager, address(this), cost, true);
            specified.settle(poolManager, address(this), packCount, true);
            returnDelta = toBeforeSwapDelta(-packCount.toInt128(), cost.toInt128());
            emit PacksBought(sender, packCount, cost);
        } else {
            // Sell back: take packs into claim inventory, pay USDC from the claim float.
            uint256 payout = quoteSell(packCount);
            specified.take(poolManager, address(this), packCount, true);
            unspecified.settle(poolManager, address(this), payout, true);
            returnDelta = toBeforeSwapDelta(packCount.toInt128(), -payout.toInt128());
            emit PacksSold(sender, packCount, payout);
        }

        return (BaseHook.beforeSwap.selector, returnDelta, 0);
    }

    function quoteBuy(uint256 packCount) public view returns (uint256 cost) {
        if (packInventory() < packCount) revert SoldOut();
        uint256 ev = packs.evPerPack();
        if (ev == 0) revert OracleUnpriced();
        cost = packCount * ev * premiumBps / 10_000;
    }

    function quoteSell(uint256 packCount) public view returns (uint256 payout) {
        uint256 ev = packs.evPerPack();
        if (ev == 0) revert OracleUnpriced();
        payout = packCount * ev * buybackBps / 10_000;
        if (usdcFloat() < payout) revert NoBuybackFloat();
    }

    /// @notice Unsold packs held by the hook, as ERC-6909 claims.
    function packInventory() public view returns (uint256) {
        return poolManager.balanceOf(address(this), Currency.wrap(address(packs)).toId());
    }

    /// @notice USDC available for buybacks and withdrawal, as ERC-6909 claims.
    function usdcFloat() public view returns (uint256) {
        return poolManager.balanceOf(address(this), Currency.wrap(address(usdc)).toId());
    }

    /// @notice Convert the hook's real PACK balance (minted by Booster.loadBox) into claims.
    function depositInventory() external onlyOwner {
        uint256 amount = packs.balanceOf(address(this));
        poolManager.unlock(abi.encode(DEPOSIT, Currency.wrap(address(packs)), amount, address(this)));
    }

    /// @notice House revenue: sale proceeds minus buybacks, paid out as real USDC.
    function withdraw(address to, uint256 amount) external onlyOwner {
        poolManager.unlock(abi.encode(WITHDRAW, Currency.wrap(address(usdc)), amount, to));
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (uint8 action, Currency currency, uint256 amount, address to) =
            abi.decode(data, (uint8, Currency, uint256, address));
        if (action == DEPOSIT) {
            currency.settle(poolManager, address(this), amount, false);
            currency.take(poolManager, address(this), amount, true);
        } else {
            currency.settle(poolManager, address(this), amount, true);
            currency.take(poolManager, to, amount, false);
        }
        return "";
    }
}
