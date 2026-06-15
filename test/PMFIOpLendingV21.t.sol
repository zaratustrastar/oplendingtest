// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {
    PMFIPositionFactoryV21,
    PMFIPositionVaultV21,
    PMFIPrimaryMarketplaceV21,
    PMFILegTokenV21
} from "../src/PMFIOpLendingV21.sol";

contract MockERC20Decimals is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockFeeOnTransfer is MockERC20Decimals {
    constructor() MockERC20Decimals("Fee Token", "FEE", 18) {}

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && value > 100) {
            uint256 fee = value / 100;
            super._update(from, address(0), fee);
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}

contract PMFIOpLendingV21Test is TestBase {
    MockERC20Decimals internal usdc;
    MockERC20Decimals internal collateral;
    PMFIPositionFactoryV21 internal factory;
    PMFIPrimaryMarketplaceV21 internal marketplace;

    address internal borrower = makeAddr("borrower");
    address internal lender1 = makeAddr("lender1");
    address internal lender2 = makeAddr("lender2");
    address internal feeRecipient = makeAddr("feeRecipient");

    uint256 internal constant ONE = 1e18;
    uint256 internal constant CREATION_FEE = 0.0001 ether;

    function setUp() public {
        usdc = new MockERC20Decimals("USD Coin", "USDC", 6);
        collateral = new MockERC20Decimals("Collateral", "COL", 18);
        factory = new PMFIPositionFactoryV21(IERC20Metadata(address(usdc)), feeRecipient, address(this));
        marketplace = PMFIPrimaryMarketplaceV21(factory.marketplace());
        factory.setCollateralAllowed(address(collateral), true);

        collateral.mint(borrower, 1_000_000 * ONE);
        usdc.mint(borrower, 1_000_000e6);
        usdc.mint(lender1, 1_000_000e6);
        usdc.mint(lender2, 1_000_000e6);
        vm.deal(borrower, 10 ether);
    }

    function _create(uint256 collateralAmount, uint256 raiseUsdc, uint256 repayUsdc)
        internal
        returns (PMFIPositionVaultV21 vault, uint256 saleId)
    {
        PMFIPositionFactoryV21.CreatePositionParams memory params = PMFIPositionFactoryV21.CreatePositionParams({
            collateral: IERC20Metadata(address(collateral)),
            collateralAmount: collateralAmount,
            targetRaiseUsdc: raiseUsdc,
            totalRepaymentUsdc: repayUsdc,
            fundingDeadline: block.timestamp + 3 days,
            repaymentDeadline: block.timestamp + 33 days,
            namePrefix: "PMFI COL",
            symbolPrefix: "pCOL"
        });

        vm.startPrank(borrower);
        collateral.approve(address(factory), collateralAmount);
        (address vaultAddress, uint256 createdSaleId) = factory.createPosition{value: CREATION_FEE}(params);
        vm.stopPrank();

        vault = PMFIPositionVaultV21(vaultAddress);
        saleId = createdSaleId;
    }

    function _buy(address lender, uint256 saleId, uint256 pAmount)
        internal
        returns (uint256 sellerPrice, uint256 fee, uint256 total)
    {
        (sellerPrice, fee, total) = marketplace.quoteTotalPayment(saleId, pAmount);
        vm.startPrank(lender);
        usdc.approve(address(marketplace), total);
        marketplace.buy(saleId, pAmount, total);
        vm.stopPrank();
    }

    function test_CreatePositionIsAtomicAndVerified() public {
        uint256 amount = 100 * ONE;
        (PMFIPositionVaultV21 vault, uint256 saleId) = _create(amount, 100e6, 120e6);

        assertTrue(factory.isVault(address(vault)));
        assertEq(factory.creatorOf(address(vault)), borrower);
        assertEq(address(vault.usdc()), address(usdc));
        assertEq(address(vault.collateral()), address(collateral));
        assertEq(collateral.balanceOf(address(vault)), amount);
        assertEq(vault.P().balanceOf(address(marketplace)), amount);
        assertEq(vault.N().balanceOf(borrower), amount);
        assertFalse(vault.N().transfersEnabled());
        assertEq(marketplace.saleIdPlusOneByVault(address(vault)), saleId + 1);
    }

    function test_NCannotTransferBeforeFundingCloses() public {
        (PMFIPositionVaultV21 vault,) = _create(100 * ONE, 100e6, 120e6);

        vm.prank(borrower);
        vm.expectRevert(PMFILegTokenV21.TransfersDisabled.selector);
        vault.N().transfer(lender1, ONE);
    }

    function test_FullFillClosesFundingAndAllowsNTransfers() public {
        uint256 amount = 100 * ONE;
        (PMFIPositionVaultV21 vault, uint256 saleId) = _create(amount, 100e6, 120e6);

        _buy(lender1, saleId, amount);

        assertTrue(vault.fundingClosed());
        assertTrue(vault.N().transfersEnabled());
        assertEq(vault.P().balanceOf(lender1), amount);
        assertEq(usdc.balanceOf(borrower), 100e6);
    }

    function test_PartialFillCancelBurnsUnsoldLegsAndRefundsCollateral() public {
        uint256 amount = 100 * ONE;
        (PMFIPositionVaultV21 vault, uint256 saleId) = _create(amount, 100e6, 120e6);

        _buy(lender1, saleId, 40 * ONE);

        uint256 borrowerCollateralBefore = collateral.balanceOf(borrower);
        vm.prank(borrower);
        marketplace.cancel(saleId);

        assertTrue(vault.fundingClosed());
        assertEq(vault.pairedN(), 60 * ONE);
        assertEq(vault.P().totalSupply(), 40 * ONE);
        assertEq(vault.N().totalSupply(), 40 * ONE);
        assertEq(collateral.balanceOf(address(vault)), 40 * ONE);
        assertEq(collateral.balanceOf(borrower), borrowerCollateralBefore + 60 * ONE);
        assertEq(vault.repaymentRequiredUsdc(), 48e6);
    }

    function test_SplitExercisesCollectExactRepaymentAndSettleEarly() public {
        uint256 amount = 3 * ONE;
        (PMFIPositionVaultV21 vault, uint256 saleId) = _create(amount, 9e6, 10e6);
        _buy(lender1, saleId, amount);

        vm.startPrank(borrower);
        usdc.approve(address(vault), 10e6);
        vault.exercise(ONE);
        vault.exercise(2 * ONE);
        vm.stopPrank();

        assertEq(vault.usdcPaid(), 10e6);
        assertEq(vault.N().totalSupply(), 0);
        assertTrue(vault.canSettleEarly());

        vm.prank(lender1);
        vault.settleAndRedeemP(amount);

        assertEq(usdc.balanceOf(lender1), 1_000_000e6 - 9_009_000 + 10e6);
        assertEq(vault.P().totalSupply(), 0);
    }

    function test_PartialFundingRepaymentIsProRataAndExact() public {
        uint256 amount = 100 * ONE;
        (PMFIPositionVaultV21 vault, uint256 saleId) = _create(amount, 100e6, 120e6);
        _buy(lender1, saleId, 40 * ONE);

        vm.prank(borrower);
        marketplace.cancel(saleId);

        vm.startPrank(borrower);
        usdc.approve(address(vault), 48e6);
        vault.exercise(13 * ONE);
        vault.exercise(27 * ONE);
        vm.stopPrank();

        assertEq(vault.usdcPaid(), 48e6);
        assertTrue(vault.canSettleEarly());

        vm.prank(lender1);
        vault.settleAndRedeemP(40 * ONE);
        assertEq(usdc.balanceOf(lender1), 1_000_000e6 - 40_040_000 + 48e6);
    }

    function test_NoRepaymentGivesPHolderCollateralFallback() public {
        uint256 amount = 100 * ONE;
        (PMFIPositionVaultV21 vault, uint256 saleId) = _create(amount, 100e6, 120e6);
        _buy(lender1, saleId, amount);

        vm.warp(vault.repaymentDeadline() + 1);
        vm.prank(lender1);
        vault.settleAndRedeemP(amount);

        assertEq(collateral.balanceOf(lender1), amount);
        assertEq(vault.P().totalSupply(), 0);
    }

    function test_MixedRepaymentGivesPHolderUsdcAndCollateral() public {
        uint256 amount = 100 * ONE;
        (PMFIPositionVaultV21 vault, uint256 saleId) = _create(amount, 100e6, 120e6);
        _buy(lender1, saleId, amount);

        vm.startPrank(borrower);
        usdc.approve(address(vault), 60e6);
        vault.exercise(50 * ONE);
        vm.stopPrank();

        vm.warp(vault.repaymentDeadline() + 1);
        vm.prank(lender1);
        vault.settleAndRedeemP(amount);

        assertEq(collateral.balanceOf(lender1), 50 * ONE);
        assertEq(usdc.balanceOf(lender1), 1_000_000e6 - 100_100_000 + 60e6);
    }

    function test_MultipleLendersAndCumulativeFee() public {
        uint256 amount = 100 * ONE;
        (PMFIPositionVaultV21 vault, uint256 saleId) = _create(amount, 100e6, 120e6);

        _buy(lender1, saleId, 33 * ONE);
        _buy(lender2, saleId, 67 * ONE);

        assertTrue(vault.fundingClosed());
        assertEq(vault.P().balanceOf(lender1), 33 * ONE);
        assertEq(vault.P().balanceOf(lender2), 67 * ONE);
        assertEq(marketplace.accruedProtocolFees(), 100_000); // 0.1 USDC
    }

    function test_PauseBlocksNewRiskButNotCancellation() public {
        factory.setCreationPaused(true);

        PMFIPositionFactoryV21.CreatePositionParams memory params = PMFIPositionFactoryV21.CreatePositionParams({
            collateral: IERC20Metadata(address(collateral)),
            collateralAmount: 100 * ONE,
            targetRaiseUsdc: 100e6,
            totalRepaymentUsdc: 120e6,
            fundingDeadline: block.timestamp + 3 days,
            repaymentDeadline: block.timestamp + 33 days,
            namePrefix: "PMFI COL",
            symbolPrefix: "pCOL"
        });

        vm.startPrank(borrower);
        collateral.approve(address(factory), 100 * ONE);
        vm.expectRevert(PMFIPositionFactoryV21.CreationPaused.selector);
        factory.createPosition{value: CREATION_FEE}(params);
        vm.stopPrank();

        factory.setCreationPaused(false);
        (PMFIPositionVaultV21 vault, uint256 saleId) = _create(100 * ONE, 100e6, 120e6);
        factory.setPurchasesPaused(true);

        (,, uint256 total) = marketplace.quoteTotalPayment(saleId, 10 * ONE);
        vm.startPrank(lender1);
        usdc.approve(address(marketplace), total);
        vm.expectRevert(PMFIPrimaryMarketplaceV21.PurchasesPaused.selector);
        marketplace.buy(saleId, 10 * ONE, total);
        vm.stopPrank();

        vm.prank(borrower);
        marketplace.cancel(saleId);
        assertTrue(vault.closedWithoutOutstandingP());
        assertEq(collateral.balanceOf(borrower), 1_000_000 * ONE);
    }

    function test_FeeOnTransferCollateralIsRejected() public {
        MockFeeOnTransfer feeToken = new MockFeeOnTransfer();
        factory.setCollateralAllowed(address(feeToken), true);
        feeToken.mint(borrower, 100 * ONE);

        PMFIPositionFactoryV21.CreatePositionParams memory params = PMFIPositionFactoryV21.CreatePositionParams({
            collateral: IERC20Metadata(address(feeToken)),
            collateralAmount: 100 * ONE,
            targetRaiseUsdc: 100e6,
            totalRepaymentUsdc: 120e6,
            fundingDeadline: block.timestamp + 3 days,
            repaymentDeadline: block.timestamp + 33 days,
            namePrefix: "PMFI FEE",
            symbolPrefix: "pFEE"
        });

        vm.startPrank(borrower);
        feeToken.approve(address(factory), 100 * ONE);
        vm.expectRevert(PMFIPositionFactoryV21.FeeOnTransferUnsupported.selector);
        factory.createPosition{value: CREATION_FEE}(params);
        vm.stopPrank();
    }

    function test_RevertWhen_CollateralNotAllowlisted() public {
        MockERC20Decimals other = new MockERC20Decimals("Other", "OTH", 18);
        other.mint(borrower, 100 * ONE);

        PMFIPositionFactoryV21.CreatePositionParams memory params = PMFIPositionFactoryV21.CreatePositionParams({
            collateral: IERC20Metadata(address(other)),
            collateralAmount: 100 * ONE,
            targetRaiseUsdc: 100e6,
            totalRepaymentUsdc: 120e6,
            fundingDeadline: block.timestamp + 3 days,
            repaymentDeadline: block.timestamp + 33 days,
            namePrefix: "PMFI OTH",
            symbolPrefix: "pOTH"
        });

        vm.startPrank(borrower);
        other.approve(address(factory), 100 * ONE);
        vm.expectRevert(PMFIPositionFactoryV21.CollateralNotAllowed.selector);
        factory.createPosition{value: CREATION_FEE}(params);
        vm.stopPrank();
    }

    function testFuzz_SplitExerciseAlwaysCollectsExactTotal(uint16 firstUnits) public {
        firstUnits = uint16(bound(firstUnits, 1, 999));
        uint256 amount = 1_000 * ONE;
        uint256 repayment = 123_456_789;
        (PMFIPositionVaultV21 vault, uint256 saleId) = _create(amount, 100e6, repayment);
        _buy(lender1, saleId, amount);

        uint256 firstAmount = uint256(firstUnits) * ONE;
        vm.startPrank(borrower);
        usdc.approve(address(vault), repayment);
        vault.exercise(firstAmount);
        vault.exercise(amount - firstAmount);
        vm.stopPrank();

        assertEq(vault.usdcPaid(), repayment);
        assertEq(vault.repaymentRemainingUsdc(), 0);
        assertTrue(vault.canSettleEarly());
    }

    function testFuzz_SplitPurchasesDoNotChangeTotalFee(uint16 firstUnits) public {
        firstUnits = uint16(bound(firstUnits, 1, 999));
        uint256 amount = 1_000 * ONE;
        uint256 raise = 1_234_567_890;
        (PMFIPositionVaultV21 vault, uint256 saleId) = _create(amount, raise, 1_500_000_000);

        uint256 firstAmount = uint256(firstUnits) * ONE;
        _buy(lender1, saleId, firstAmount);
        _buy(lender2, saleId, amount - firstAmount);

        assertTrue(vault.fundingClosed());
        assertEq(
            marketplace.accruedProtocolFees(), (raise * marketplace.SALE_FEE_BPS()) / marketplace.BPS_DENOMINATOR()
        );
    }
}
