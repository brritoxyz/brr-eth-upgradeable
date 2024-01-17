// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {ERC1967Factory} from "solady/utils/ERC1967Factory.sol";
import {Initializable} from "solady/utils/Initializable.sol";
import {UUPSUpgradeable} from "solady/utils/UUPSUpgradeable.sol";
import {Helper} from "test/Helper.sol";

contract BrrETHUUPSUpgradeableTest is Helper {
    /*//////////////////////////////////////////////////////////////
                            upgradeToAndCall
    //////////////////////////////////////////////////////////////*/

    function testCannotUpgradeToAndCallUnauthorized() external {
        address msgSender = address(0);

        assertTrue(msgSender != _ERC1967_FACTORY.adminOf(address(vault)));

        vm.prank(msgSender);
        vm.expectRevert(ERC1967Factory.Unauthorized.selector);

        vault.upgradeToAndCall(vaultImplementation, bytes(""));
    }

    function testUpgradeToAndCall() external {
        address msgSender = _ERC1967_FACTORY.adminOf(address(vault));

        vm.prank(msgSender);
        vm.expectEmit(true, true, true, true, address(vault));

        emit UUPSUpgradeable.Upgraded(vaultImplementation);

        vault.upgradeToAndCall(vaultImplementation, bytes(""));
    }
}
