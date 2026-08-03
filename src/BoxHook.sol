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

import {Booster} from "./Booster.sol";

/// @notice Custom-curve v4 hook that sells and buys back sealed packs at the expected
/// value of the remaining box contents, quoted in native ETH. The hook is the sole
/// counterparty: it holds the unsold pack inventory and the ETH float as ERC-6909
/// claims on the PoolManager, and the pool has no LP liquidity.
///
/// Card values come from the oracle in USD (TCGplayer market); the oracle's ethUsd
/// rate converts quotes to wei.
///
/// Supported swaps (PACK must always be the specified currency, whole packs only):
///  - exact-output PACK for ETH: buy packs at EV * premiumBps
///  - exact-input PACK for ETH: sell packs back at EV * buybackBps
contract BoxHook is BaseHook, IUnlockCallback, Owned {
    using CurrencySettler for Currency;
    using CurrencyLibrary for Currency;
    using SafeCast for uint256;

    Booster public immutable packs;
    uint256 public immutable premiumBps;
    uint256 public immutable buybackBps;

    PoolKey public poolKey;

    uint8 constant DEPOSIT = 0;
    uint8 constant WITHDRAW = 1;

    event PacksBought(address indexed sender, uint256 count, uint256 costWei);
    event PacksSold(address indexed sender, uint256 count, uint256 payoutWei);

    error WrongPoolCurrencies();
    error PackMustBeSpecified();
    error OracleUnpriced();
    error SoldOut();
    error NoBuybackFloat();
    error NoExternalLiquidity();

    constructor(IPoolManager _poolManager, Booster _packs, uint256 _premiumBps, uint256 _buybackBps, address _owner)
        BaseHook(_poolManager)
        Owned(_owner)
    {
        packs = _packs;
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
        // Native ETH is always currency0; the pack token must be currency1.
        if (!key.currency0.isAddressZero() || Currency.unwrap(key.currency1) != address(packs)) {
            revert WrongPoolCurrencies();
        }
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
            // Buy: credit the swapper's ETH to the hook as claims, pay packs from claim inventory.
            uint256 cost = quoteBuy(packCount);
            unspecified.take(poolManager, address(this), cost, true);
            specified.settle(poolManager, address(this), packCount, true);
            returnDelta = toBeforeSwapDelta(-packCount.toInt128(), cost.toInt128());
            emit PacksBought(sender, packCount, cost);
        } else {
            // Sell back: take packs into claim inventory, pay ETH from the claim float.
            uint256 payout = quoteSell(packCount);
            specified.take(poolManager, address(this), packCount, true);
            unspecified.settle(poolManager, address(this), payout, true);
            returnDelta = toBeforeSwapDelta(packCount.toInt128(), -payout.toInt128());
            emit PacksSold(sender, packCount, payout);
        }

        return (BaseHook.beforeSwap.selector, returnDelta, 0);
    }

    /// @notice Cost in wei to buy packCount sealed packs.
    function quoteBuy(uint256 packCount) public view returns (uint256 costWei) {
        if (packInventory() < packCount) revert SoldOut();
        costWei = _usdToWei(packCount * packs.evPerPack() * premiumBps / 10_000);
    }

    /// @notice Payout in wei for selling packCount sealed packs back.
    function quoteSell(uint256 packCount) public view returns (uint256 payoutWei) {
        payoutWei = _usdToWei(packCount * packs.evPerPack() * buybackBps / 10_000);
        if (ethFloat() < payoutWei) revert NoBuybackFloat();
    }

    function _usdToWei(uint256 usd6) internal view returns (uint256) {
        if (usd6 == 0) revert OracleUnpriced();
        uint256 ethUsd = packs.oracle().ethUsd();
        if (ethUsd == 0) revert OracleUnpriced();
        return usd6 * 1e18 / ethUsd;
    }

    /// @notice Unsold packs held by the hook, as ERC-6909 claims.
    function packInventory() public view returns (uint256) {
        return poolManager.balanceOf(address(this), Currency.wrap(address(packs)).toId());
    }

    /// @notice ETH available for buybacks and withdrawal, as ERC-6909 claims.
    function ethFloat() public view returns (uint256) {
        return poolManager.balanceOf(address(this), CurrencyLibrary.ADDRESS_ZERO.toId());
    }

    /// @notice Convert the hook's real PACK balance (minted by Booster.loadBox) into claims.
    function depositInventory() external onlyOwner {
        uint256 amount = packs.balanceOf(address(this));
        poolManager.unlock(abi.encode(DEPOSIT, Currency.wrap(address(packs)), amount, address(this)));
    }

    /// @notice House revenue: sale proceeds minus buybacks, paid out as real ETH.
    function withdraw(address to, uint256 amount) external onlyOwner {
        poolManager.unlock(abi.encode(WITHDRAW, CurrencyLibrary.ADDRESS_ZERO, amount, to));
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
