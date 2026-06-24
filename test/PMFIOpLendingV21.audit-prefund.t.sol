// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PMFIPositionFactoryV21, PMFIPositionVaultV21} from "../src/PMFIOpLendingV21.sol";

contract AuditPrefundToken is ERC20 {
    uint8 private immutable _d;
    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) { _d = d; }
    function decimals() public view override returns (uint8) { return _d; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract PMFIOpLendingV21AuditPrefundTest is TestBase {
    uint256 constant ONE = 1e18;
    address borrower = makeAddr("prefundBorrower");

    function test_ExtraBalanceAtFutureVaultAddressPreventsInitialization() public {
        AuditPrefundToken usdc = new AuditPrefundToken("USD Coin", "USDC", 6);
        AuditPrefundToken collateral = new AuditPrefundToken("Collateral", "COL", 18);
        PMFIPositionFactoryV21 factory =
            new PMFIPositionFactoryV21(IERC20Metadata(address(usdc)), makeAddr("fees"), address(this));
        factory.setCollateralAllowed(address(collateral), true);

        collateral.mint(borrower, 100 * ONE);
        collateral.mint(address(this), 1);
        vm.deal(borrower, 1 ether);

        // The constructor's marketplace deployment consumes nonce 1; the first vault uses nonce 2.
        address futureVault = address(
            uint160(uint256(keccak256(abi.encodePacked(hex"d694", address(factory), hex"02"))))
        );
        collateral.transfer(futureVault, 1);

        PMFIPositionFactoryV21.CreatePositionParams memory p = PMFIPositionFactoryV21.CreatePositionParams({
            collateral: IERC20Metadata(address(collateral)), collateralAmount: 100 * ONE,
            targetRaiseUsdc: 100e6, totalRepaymentUsdc: 120e6,
            fundingDeadline: block.timestamp + 3 days, repaymentDeadline: block.timestamp + 33 days,
            namePrefix: "AUDIT", symbolPrefix: "AUD"
        });

        vm.startPrank(borrower);
        collateral.approve(address(factory), 100 * ONE);
        vm.expectRevert(PMFIPositionVaultV21.InsufficientCollateral.selector);
        factory.createPosition{value: factory.CREATION_FEE()}(p);
        vm.stopPrank();
    }
}
