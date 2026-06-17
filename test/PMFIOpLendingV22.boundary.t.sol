// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {PMFIPositionFactoryV22, PMFIPositionVaultV22, PMFIPrimaryMarketplaceV22} from "../src/PMFIOpLendingV22.sol";

contract V22BoundaryToken is ERC20 {
    uint8 private immutable _tokenDecimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PMFIOpLendingV22BoundaryTest is TestBase {
    uint256 internal constant ONE = 1e18;
    uint256 internal constant COLLATERAL_AMOUNT = 100 * ONE;

    V22BoundaryToken internal usdc;
    V22BoundaryToken internal collateral;

    PMFIPositionFactoryV22 internal factory;
    PMFIPrimaryMarketplaceV22 internal marketplace;

    address internal borrower = makeAddr("v22BoundaryBorrower");

    address internal lender = makeAddr("v22BoundaryLender");

    address internal keeper = makeAddr("v22BoundaryKeeper");

    address internal feeRecipient = makeAddr("v22BoundaryFees");

    function setUp() public {
        usdc = new V22BoundaryToken("USD Coin", "USDC", 6);

        collateral = new V22BoundaryToken("V2.2 Boundary Collateral", "V22BOUND", 18);

        factory = new PMFIPositionFactoryV22(IERC20Metadata(address(usdc)), feeRecipient, address(this));

        marketplace = PMFIPrimaryMarketplaceV22(factory.marketplace());

        factory.setCollateralAllowed(address(collateral), true);

        collateral.mint(borrower, 2_000 * ONE);

        usdc.mint(borrower, 2_000e6);

        usdc.mint(lender, 2_000e6);

        vm.deal(borrower, 10 ether);
    }

    function _params(uint256 fundingDeadline, uint256 repaymentDeadline)
        internal
        view
        returns (PMFIPositionFactoryV22.CreatePositionParams memory params)
    {
        params = PMFIPositionFactoryV22.CreatePositionParams({
            collateral: IERC20Metadata(address(collateral)),
            collateralAmount: COLLATERAL_AMOUNT,
            targetRaiseUsdc: 100e6,
            totalRepaymentUsdc: 120e6,
            fundingDeadline: fundingDeadline,
            repaymentDeadline: repaymentDeadline,
            namePrefix: "V22 BOUNDARY",
            symbolPrefix: "V22B"
        });
    }

    function _create(uint256 fundingDeadline, uint256 repaymentDeadline)
        internal
        returns (PMFIPositionVaultV22 vault, uint256 saleId)
    {
        PMFIPositionFactoryV22.CreatePositionParams memory params = _params(fundingDeadline, repaymentDeadline);

        uint256 creationFee = factory.CREATION_FEE();

        vm.startPrank(borrower);

        collateral.approve(address(factory), COLLATERAL_AMOUNT);

        (address vaultAddress, uint256 createdSaleId) = factory.createPosition{value: creationFee}(params);

        vm.stopPrank();

        vault = PMFIPositionVaultV22(vaultAddress);

        saleId = createdSaleId;
    }

    function _createDefault() internal returns (PMFIPositionVaultV22 vault, uint256 saleId) {
        uint256 fundingDeadline = block.timestamp + 3 days;

        uint256 repaymentDeadline = fundingDeadline + 30 days;

        return _create(fundingDeadline, repaymentDeadline);
    }

    function _buy(uint256 saleId, uint256 amount) internal {
        (,, uint256 totalPayment) = marketplace.quoteTotalPayment(saleId, amount);

        vm.startPrank(lender);

        usdc.approve(address(marketplace), totalPayment);

        marketplace.buy(saleId, amount, totalPayment);

        vm.stopPrank();
    }

    function test_RevertWhenCreationFeeIsWrong() public {
        uint256 fundingDeadline = block.timestamp + 3 days;

        uint256 repaymentDeadline = fundingDeadline + 30 days;

        PMFIPositionFactoryV22.CreatePositionParams memory params = _params(fundingDeadline, repaymentDeadline);

        uint256 wrongFee = factory.CREATION_FEE() - 1;

        vm.startPrank(borrower);

        collateral.approve(address(factory), COLLATERAL_AMOUNT);

        (bool wrongFeeAccepted,) = address(factory).call{value: wrongFee}(
            abi.encodeWithSelector(PMFIPositionFactoryV22.createPosition.selector, params)
        );

        assertFalse(wrongFeeAccepted);

        vm.stopPrank();
    }

    function test_MinimumFundingPeriodBoundary() public {
        uint256 minimumPeriod = factory.MIN_FUNDING_PERIOD();

        uint256 fundingDeadline = block.timestamp + minimumPeriod;

        uint256 repaymentDeadline = fundingDeadline + 30 days;

        (PMFIPositionVaultV22 vault,) = _create(fundingDeadline, repaymentDeadline);

        assertTrue(factory.isVault(address(vault)));

        uint256 invalidFundingDeadline = block.timestamp + minimumPeriod - 1;

        uint256 invalidRepaymentDeadline = invalidFundingDeadline + 30 days;

        PMFIPositionFactoryV22.CreatePositionParams memory invalidParams =
            _params(invalidFundingDeadline, invalidRepaymentDeadline);

        uint256 creationFee = factory.CREATION_FEE();

        vm.startPrank(borrower);

        collateral.approve(address(factory), COLLATERAL_AMOUNT);

        (bool shortPeriodAccepted,) = address(factory).call{value: creationFee}(
            abi.encodeWithSelector(PMFIPositionFactoryV22.createPosition.selector, invalidParams)
        );

        assertFalse(shortPeriodAccepted);

        vm.stopPrank();
    }

    function test_SaleExpiresAtExactFundingDeadline() public {
        uint256 fundingDeadline = block.timestamp + factory.MIN_FUNDING_PERIOD();

        uint256 repaymentDeadline = fundingDeadline + 30 days;

        (PMFIPositionVaultV22 vault, uint256 saleId) = _create(fundingDeadline, repaymentDeadline);

        (,, uint256 totalPayment) = marketplace.quoteTotalPayment(saleId, ONE);

        vm.startPrank(lender);

        usdc.approve(address(marketplace), totalPayment);

        vm.stopPrank();

        vm.warp(fundingDeadline);

        vm.startPrank(lender);

        (bool buySucceeded,) = address(marketplace)
            .call(abi.encodeWithSelector(PMFIPrimaryMarketplaceV22.buy.selector, saleId, ONE, totalPayment));

        assertFalse(buySucceeded);

        vm.stopPrank();

        vm.prank(keeper);
        marketplace.closeExpired(saleId);

        assertTrue(vault.fundingClosed());

        assertEq(vault.collateralRefundClaim(), COLLATERAL_AMOUNT);

        assertEq(vault.accountedCollateral(), 0);

        assertEq(vault.P().totalSupply(), 0);

        assertEq(vault.N().totalSupply(), 0);
    }

    function test_FullRepaymentAllowedAtExactDeadline() public {
        (PMFIPositionVaultV22 vault, uint256 saleId) = _createDefault();

        _buy(saleId, COLLATERAL_AMOUNT);

        uint256 required = vault.repaymentRequiredUsdc();

        uint256 borrowerCollateralBefore = collateral.balanceOf(borrower);

        vm.warp(vault.repaymentDeadline());

        vm.startPrank(borrower);

        usdc.approve(address(vault), required);

        vault.repayInFull();

        vm.stopPrank();

        assertEq(collateral.balanceOf(borrower) - borrowerCollateralBefore, COLLATERAL_AMOUNT);

        assertTrue(vault.canSettleEarly());

        vault.settle();

        uint256 lenderUsdcBefore = usdc.balanceOf(lender);

        uint256 lenderCollateralBefore = collateral.balanceOf(lender);

        vm.prank(lender);

        vault.redeemP(COLLATERAL_AMOUNT);

        assertEq(usdc.balanceOf(lender) - lenderUsdcBefore, required);

        assertEq(collateral.balanceOf(lender) - lenderCollateralBefore, 0);

        assertEq(vault.usdcPoolRemaining(), 0);
    }

    function test_RepaymentRejectedAfterDeadlineAndDefaultSettles() public {
        (PMFIPositionVaultV22 vault, uint256 saleId) = _createDefault();

        _buy(saleId, COLLATERAL_AMOUNT);

        uint256 required = vault.repaymentRequiredUsdc();

        vm.startPrank(borrower);

        usdc.approve(address(vault), required);

        vm.stopPrank();

        vm.warp(vault.repaymentDeadline() + 1);

        vm.startPrank(borrower);

        (bool repaymentSucceeded,) =
            address(vault).call(abi.encodeWithSelector(PMFIPositionVaultV22.repayInFull.selector));

        assertFalse(repaymentSucceeded);

        vm.stopPrank();

        assertEq(vault.usdcPaid(), 0);

        assertEq(vault.accountedCollateral(), COLLATERAL_AMOUNT);

        vault.settle();

        uint256 lenderUsdcBefore = usdc.balanceOf(lender);

        uint256 lenderCollateralBefore = collateral.balanceOf(lender);

        vm.prank(lender);

        vault.redeemP(COLLATERAL_AMOUNT);

        assertEq(usdc.balanceOf(lender) - lenderUsdcBefore, 0);

        assertEq(collateral.balanceOf(lender) - lenderCollateralBefore, COLLATERAL_AMOUNT);

        assertEq(vault.accountedCollateral(), 0);
    }

    function test_EarlySettlementRejectedBeforeFullRepayment() public {
        (PMFIPositionVaultV22 vault, uint256 saleId) = _createDefault();

        _buy(saleId, COLLATERAL_AMOUNT);

        assertFalse(vault.canSettleEarly());

        (bool settlementSucceeded,) = address(vault).call(abi.encodeWithSelector(PMFIPositionVaultV22.settle.selector));

        assertFalse(settlementSucceeded);

        assertFalse(vault.settled());
    }

    function test_PurchasePauseBlocksBuyButNotBorrowerCancellation() public {
        (PMFIPositionVaultV22 vault, uint256 saleId) = _createDefault();

        (,, uint256 totalPayment) = marketplace.quoteTotalPayment(saleId, ONE);

        vm.startPrank(lender);

        usdc.approve(address(marketplace), totalPayment);

        vm.stopPrank();

        factory.setPurchasesPaused(true);

        vm.startPrank(lender);

        (bool buySucceeded,) = address(marketplace)
            .call(abi.encodeWithSelector(PMFIPrimaryMarketplaceV22.buy.selector, saleId, ONE, totalPayment));

        assertFalse(buySucceeded);

        vm.stopPrank();

        vm.prank(borrower);
        marketplace.cancel(saleId);

        assertTrue(vault.fundingClosed());

        assertEq(vault.collateralRefundClaim(), COLLATERAL_AMOUNT);

        assertEq(vault.P().totalSupply(), 0);

        assertEq(vault.N().totalSupply(), 0);
    }
}
