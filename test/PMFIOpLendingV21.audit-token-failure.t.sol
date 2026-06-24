// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PMFIPositionFactoryV21, PMFIPositionVaultV21, PMFIPrimaryMarketplaceV21} from "../src/PMFIOpLendingV21.sol";

contract AuditBaseToken is ERC20 {
    uint8 private immutable _d;
    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) { _d = d; }
    function decimals() public view override returns (uint8) { return _d; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract AuditBlockingCollateral is AuditBaseToken {
    address public blockedSender;
    bool public blocked;
    error OutboundBlocked();
    constructor() AuditBaseToken("Blocking Collateral", "BCOL", 18) {}
    function configure(address sender, bool value) external { blockedSender = sender; blocked = value; }
    function _update(address from, address to, uint256 value) internal override {
        if (blocked && from == blockedSender && from != address(0) && to != address(0)) revert OutboundBlocked();
        super._update(from, to, value);
    }
}

contract PMFIOpLendingV21AuditTokenFailureTest is TestBase {
    uint256 constant ONE = 1e18;
    AuditBaseToken usdc;
    AuditBlockingCollateral collateral;
    PMFIPositionFactoryV21 factory;
    PMFIPrimaryMarketplaceV21 marketplace;
    address borrower = makeAddr("tokenFailureBorrower");
    address lender = makeAddr("tokenFailureLender");

    function setUp() public {
        usdc = new AuditBaseToken("USD Coin", "USDC", 6);
        collateral = new AuditBlockingCollateral();
        factory = new PMFIPositionFactoryV21(IERC20Metadata(address(usdc)), makeAddr("fees"), address(this));
        marketplace = PMFIPrimaryMarketplaceV21(factory.marketplace());
        factory.setCollateralAllowed(address(collateral), true);
        collateral.mint(borrower, 1_000 * ONE);
        usdc.mint(borrower, 1_000e6);
        usdc.mint(lender, 1_000e6);
        vm.deal(borrower, 1 ether);
    }

    function _create() internal returns (PMFIPositionVaultV21 vault, uint256 saleId) {
        PMFIPositionFactoryV21.CreatePositionParams memory p = PMFIPositionFactoryV21.CreatePositionParams({
            collateral: IERC20Metadata(address(collateral)), collateralAmount: 100 * ONE,
            targetRaiseUsdc: 100e6, totalRepaymentUsdc: 120e6,
            fundingDeadline: block.timestamp + 3 days, repaymentDeadline: block.timestamp + 33 days,
            namePrefix: "AUDIT", symbolPrefix: "AUD"
        });
        vm.startPrank(borrower);
        collateral.approve(address(factory), 100 * ONE);
        (address vaultAddress, uint256 id) = factory.createPosition{value: factory.CREATION_FEE()}(p);
        vm.stopPrank();
        vault = PMFIPositionVaultV21(vaultAddress);
        saleId = id;
    }

    function _buy(uint256 saleId, uint256 amount) internal {
        (,, uint256 total) = marketplace.quoteTotalPayment(saleId, amount);
        vm.startPrank(lender);
        usdc.approve(address(marketplace), total);
        marketplace.buy(saleId, amount, total);
        vm.stopPrank();
    }

    function test_CollateralFailurePreventsExpiredPartialSaleClosure() public {
        (PMFIPositionVaultV21 vault, uint256 saleId) = _create();
        _buy(saleId, 40 * ONE);
        collateral.configure(address(vault), true);
        vm.warp(vault.fundingDeadline());
        vm.expectRevert(AuditBlockingCollateral.OutboundBlocked.selector);
        marketplace.closeExpired(saleId);
        assertFalse(vault.fundingClosed());
        vm.warp(vault.repaymentDeadline() + 1);
        vm.expectRevert(PMFIPositionVaultV21.FundingStillOpen.selector);
        vault.settle();
    }

    function test_CollateralFailurePreventsUsdcPartOfMixedRedemption() public {
        (PMFIPositionVaultV21 vault, uint256 saleId) = _create();
        _buy(saleId, 100 * ONE);
        vm.startPrank(borrower);
        usdc.approve(address(vault), 60e6);
        vault.exercise(50 * ONE);
        vm.stopPrank();
        collateral.configure(address(vault), true);
        vm.warp(vault.repaymentDeadline() + 1);
        vault.settle();
        uint256 lenderBefore = usdc.balanceOf(lender);
        vm.prank(lender);
        vm.expectRevert(AuditBlockingCollateral.OutboundBlocked.selector);
        vault.redeemP(100 * ONE);
        assertEq(usdc.balanceOf(lender), lenderBefore);
        assertEq(usdc.balanceOf(address(vault)), 60e6);
    }
}
