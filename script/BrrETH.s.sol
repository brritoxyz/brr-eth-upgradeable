// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {ERC1967Factory} from "solady/utils/ERC1967Factory.sol";
import {BrrETH} from "src/BrrETH.sol";

contract BrrETHScript is Script {
    ERC1967Factory private constant _ERC1967_FACTORY =
        ERC1967Factory(0x0000000000006396FF2a80c067f99B3d2Ab4Df24);
    address private constant _BURN_ADDRESS =
        0x000000000000000000000000000000000000dEaD;
    address private constant _ROUTER =
        0xafaE5a94e6F1C79D40F5460c47589BAD5c123B9c;
    address private constant _COMET =
        0x46e6b214b524310239732D51387075E0e70970bf;
    address private constant _COMET_REWARDS =
        0x123964802e6ABabBE1Bc9547D72Ef1B69B00A6b1;
    uint256 private constant _INITIAL_REWARD_FEE = 1_000;
    uint256 private constant _INITIAL_DEPOSIT_AMOUNT = 0.01 ether;

    function run() public {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        address admin = vm.envAddress("OWNER");
        BrrETH brrETH = BrrETH(
            _ERC1967_FACTORY.deployAndCall(
                address(new BrrETH()),
                admin,
                abi.encodeWithSelector(
                    BrrETH.initialize.selector,
                    _COMET_REWARDS,
                    _ROUTER,
                    _INITIAL_REWARD_FEE,
                    admin,
                    admin
                )
            )
        );

        brrETH.deposit{value: _INITIAL_DEPOSIT_AMOUNT}(_BURN_ADDRESS, 1);

        vm.stopBroadcast();
    }
}
