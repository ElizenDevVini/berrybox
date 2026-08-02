// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {BoxHook} from "../src/BoxHook.sol";
import {Booster} from "../src/Booster.sol";
import {CardVault} from "../src/CardVault.sol";
import {CardOracle} from "../src/CardOracle.sol";
import {MockUSDC} from "../src/MockUSDC.sol";

/// @notice Full local deployment: v4 PoolManager, swap router, tokens, hook, seeded box.
contract Deploy is Script {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    address constant DEMO_USER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266; // anvil #0

    PoolManager pm;
    PoolSwapTest router;
    MockUSDC usdc;
    CardOracle oracle;
    CardVault vault;
    Booster packs;
    BoxHook hook;

    function run() external {
        vm.startBroadcast();

        pm = new PoolManager(msg.sender);
        router = new PoolSwapTest(IPoolManager(address(pm)));
        usdc = new MockUSDC();
        oracle = new CardOracle();
        vault = new CardVault("http://localhost:5173/card/");
        packs = new Booster(oracle, vault);
        vault.setBooster(address(packs));

        // Seed values only; scripts/oracle.mjs overwrites with live TCGplayer market prices.
        uint16[] memory ids = new uint16[](8);
        uint256[] memory prices = new uint256[](8);
        (ids[0], prices[0]) = (1, 250e6); // luffy OP05-119 SEC alt art
        (ids[1], prices[1]) = (2, 4000e6); // shanks OP01-120 SEC manga
        (ids[2], prices[2]) = (3, 250e6); // zoro OP01-025 SR parallel
        (ids[3], prices[3]) = (4, 4e6); // nami OP01-016
        (ids[4], prices[4]) = (5, 530_000); // sanji OP01-013
        (ids[5], prices[5]) = (6, 580_000); // chopper OP01-015
        (ids[6], prices[6]) = (7, 250_000); // usopp OP01-004
        (ids[7], prices[7]) = (8, 490_000); // robin OP01-017
        oracle.setPrices(ids, prices);

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory ctorArgs =
            abi.encode(IPoolManager(address(pm)), packs, usdc, uint256(11_500), uint256(9_000), msg.sender);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(BoxHook).creationCode, ctorArgs);
        hook = new BoxHook{salt: salt}(IPoolManager(address(pm)), packs, usdc, 11_500, 9_000, msg.sender);
        require(address(hook) == hookAddress, "hook address mismatch");

        // 24-card box: 3 chase singles, 21 commons
        uint16[] memory manifest = new uint16[](24);
        manifest[0] = 1;
        manifest[1] = 2;
        manifest[2] = 3;
        uint256 m = 3;
        for (uint256 i = 0; i < 5; i++) manifest[m++] = 4;
        for (uint256 i = 0; i < 4; i++) manifest[m++] = 5;
        for (uint256 i = 0; i < 4; i++) manifest[m++] = 6;
        for (uint256 i = 0; i < 4; i++) manifest[m++] = 7;
        for (uint256 i = 0; i < 4; i++) manifest[m++] = 8;
        packs.loadBox(manifest, address(hook));
        hook.depositInventory();

        bool packIs0 = address(packs) < address(usdc);
        (Currency c0, Currency c1) = packIs0
            ? (Currency.wrap(address(packs)), Currency.wrap(address(usdc)))
            : (Currency.wrap(address(usdc)), Currency.wrap(address(packs)));
        PoolKey memory key = PoolKey(c0, c1, 0, 60, IHooks(hook));
        pm.initialize(key, SQRT_PRICE_1_1);

        usdc.mint(DEMO_USER, 50_000e6);

        vm.stopBroadcast();

        string memory json = string.concat(
            '{"poolManager":"', vm.toString(address(pm)),
            '","swapRouter":"', vm.toString(address(router)),
            '","usdc":"', vm.toString(address(usdc)),
            '","oracle":"', vm.toString(address(oracle)),
            '","vault":"', vm.toString(address(vault)),
            '","booster":"', vm.toString(address(packs)),
            '","hook":"', vm.toString(address(hook)),
            '","packIsCurrency0":', packIs0 ? "true" : "false", "}"
        );
        vm.writeFile("./web/src/addresses.json", json);
    }
}
