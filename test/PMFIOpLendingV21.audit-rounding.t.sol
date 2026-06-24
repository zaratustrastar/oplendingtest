// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PMFIPositionFactoryV21, PMFIPrimaryMarketplaceV21} from "../src/PMFIOpLendingV21.sol";

contract AuditRoundingToken is ERC20 {
    uint8 private immutable _d;
    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) { _d = d; }
    function decimals() public view override returns (uint8) { return _d; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract PMFIOpLendingV21AuditRoundingTest is TestBase {
    uint256 constant ONE = 1e18;
    AuditRoundingToken usdc;
    AuditRoundingToken collateral;
    PMFIPositionFactoryV21 factory;
    PMFIPrimaryMarketplaceV21 marketplace;
    address borrower = makeAddr("auditBorrower");
    address lender = makeAddr("auditLender");

    function setUp() public {
        usdc = new AuditRoundingToken("USD Coin", "USDC", 6);
        collateral = new AuditRoundingToken("Collateral", "COL", 18);
        factory = new PMFIPositionFactoryV21(IERC20Metadata(address(usdc)), makeAddr("fees"), address(this));
        marketplace = PMFIPrimaryMarketplaceV21(factory.marketplace());
        factory.setCollateralAllowed(address(collateral), true);
        collateral.mint(borrower, 6 * ONE);
        usdc.mint(lender, 100);
        vm.deal(borrower, 1 ether);
    }

    function test_PartialFragmentedFillsUndercollectBeforeCancellation() public {
        PMFIPositionFactoryV21.CreatePositionParams memory p = PMFIPositionFactoryV21.CreatePositionParams({
            collateral: IERC20Metadata(address(collateral)), collateralAmount: 6 * ONE,
            targetRaiseUsdc: 10, totalRepaymentUsdc: 11,
            fundingDeadline: block.timestamp + 3 days, repaymentDeadline: block.timestamp + 33 days,
            namePrefix: "AUDIT", symbolPrefix: "AUD"
        });
        vm.startPrank(borrower);
        collateral.approve(address(factory), 6 * ONE);
        (, uint256 saleId) = factory.createPosition{value: factory.CREATION_FEE()}(p);
        vm.stopPrank();

        uint256 beforeBalance = usdc.balanceOf(borrower);
        for (uint256 i = 0; i < 3; i++) {
            (,, uint256 total) = marketplace.quoteTotalPayment(saleId, ONE);
            vm.startPrank(lender);
            usdc.approve(address(marketplace), total);
            marketplace.buy(saleId, ONE, total);
            vm.stopPrank();
        }

        uint256 raised = usdc.balanceOf(borrower) - beforeBalance;
        assertEq(raised, 3);
        assertTrue(raised < 5); // floor(10 * 3 / 6)

        vm.prank(borrower);
        marketplace.cancel(saleId);
    }
}
