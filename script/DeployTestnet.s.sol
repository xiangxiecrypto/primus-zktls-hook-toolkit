// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC8183} from "@erc8183/ERC8183.sol";
import {MockUSDC} from "@erc8183/mocks/MockUSDC.sol";
import {ZkTlsAttestationHook} from "@erc8183-hooks/hooks/ZkTlsAttestationHook.sol";

/// @notice Full testnet deployment: ERC8183 (UUPS proxy) + MockUSDC + the
///         hook, all wired together against the real Primus PrimusZKTLS at
///         0xCE7cefB3B5A7eB44B59F60327A53c9Ce53B0afdE on Base Sepolia.
///
/// Run with:
///   PROVIDER_ADDR=0x... \
///   forge script script/DeployTestnet.s.sol:DeployTestnet \
///       --rpc-url base_sepolia --broadcast \
///       --private-key $DEPLOYER_KEY
///
/// The deployer becomes admin + client + evaluator in the demo lifecycle;
/// PROVIDER_ADDR is the provider role (must differ from deployer).
contract DeployTestnet is Script {
    address constant PRIMUS_BASE_SEPOLIA = 0xCE7cefB3B5A7eB44B59F60327A53c9Ce53B0afdE;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address provider = vm.envAddress("PROVIDER_ADDR");
        require(deployer != provider, "deployer must differ from provider");

        // Pass the key explicitly so both simulation and the real broadcast
        // use the same sender — `vm.startBroadcast()` without an arg falls
        // back to Forge's DefaultSender during simulation, which then fails
        // the ADMIN_ROLE check on setHookWhitelist.
        vm.startBroadcast(deployerKey);

        // 1) ERC8183 — deploy implementation, then a UUPS proxy initialised
        //    with the deployer as both treasury and admin.
        ERC8183 impl = new ERC8183();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(ERC8183.initialize, (deployer, deployer))
        );
        ERC8183 core = ERC8183(address(proxy));

        // 2) MockUSDC — payment token. Mint a balance to deployer so the
        //    end-to-end lifecycle has something to escrow, even though the
        //    demo job uses a zero-budget shortcut.
        MockUSDC usdc = new MockUSDC();
        usdc.mint(deployer, 1_000_000 * 1e6); // 1M USDC, plenty

        // 3) The hook — points at the deployed Primus verifier and our core.
        //    Deployer is also the hook's owner (controls verifier rotation +
        //    customVerifier allowlist).
        ZkTlsAttestationHook hook = new ZkTlsAttestationHook(address(core), PRIMUS_BASE_SEPOLIA, deployer);

        // 4) Wire up — admin permissions: whitelist the hook and allow USDC.
        core.setHookWhitelist(address(hook), true);
        core.setPaymentTokenAllowed(address(usdc), true);

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== Deployed on Base Sepolia ===");
        console2.log("deployer        :", deployer);
        console2.log("provider (role) :", provider);
        console2.log("ERC8183 core    :", address(core));
        console2.log("ERC8183 impl    :", address(impl));
        console2.log("MockUSDC        :", address(usdc));
        console2.log("Hook            :", address(hook));
        console2.log("Primus verifier :", PRIMUS_BASE_SEPOLIA);
        console2.log("");
        console2.log("BaseScan        : https://sepolia.basescan.org/address/");
    }
}
