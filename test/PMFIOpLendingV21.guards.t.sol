// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {
    PMFIPositionConfigV21,
    PMFILegTokenV21,
    PMFIPositionFactoryV21,
    PMFIPositionVaultV21,
    PMFIPrimaryMarketplaceV21
} from "../src/PMFIOpLendingV21.sol";

contract GuardToken is ERC20 {
    uint8 private immutable _customDecimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _customDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _customDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract RejectEthRecipient {
    receive() external payable {
        revert("ETH rejected");
    }

    function withdraw(PMFIPositionFactoryV21 factory) external {
        factory.withdrawCreationFees();
    }
}

contract PMFIOpLendingV21GuardsTest is TestBase {
    uint256 internal constant ONE = 1e18;
    uint256 internal constant CREATION_FEE = 0.0001 ether;

    GuardToken internal usdc;
    GuardToken internal collateral;

    PMFIPositionFactoryV21 internal factory;
    PMFIPrimaryMarketplaceV21 internal marketplace;

    address internal borrower = makeAddr("guardBorrower");
    address internal lender = makeAddr("guardLender");
    address internal attacker = makeAddr("guardAttacker");
    address internal feeRecipient = makeAddr("guardFeeRecipient");

    function setUp() public {
        usdc = new GuardToken("USD Coin", "USDC", 6);
        collateral = new GuardToken("Guard Collateral", "GCOL", 18);

        factory = new PMFIPositionFactoryV21(IERC20Metadata(address(usdc)), feeRecipient, address(this));

        marketplace = PMFIPrimaryMarketplaceV21(factory.marketplace());

        factory.setCollateralAllowed(address(collateral), true);

        collateral.mint(borrower, 1_000_000 * ONE);
        collateral.mint(address(this), 1_000_000 * ONE);

        usdc.mint(borrower, 1_000_000e6);
        usdc.mint(lender, 1_000_000e6);

        vm.deal(borrower, 10 ether);
    }

    // Used when a local marketplace treats this test contract
    // as its configured factory.
    function isVault(address) external pure returns (bool) {
        return false;
    }

    function _params(IERC20Metadata collateralToken)
        internal
        view
        returns (PMFIPositionFactoryV21.CreatePositionParams memory params)
    {
        params = PMFIPositionFactoryV21.CreatePositionParams({
            collateral: collateralToken,
            collateralAmount: 100 * ONE,
            targetRaiseUsdc: 100e6,
            totalRepaymentUsdc: 120e6,
            fundingDeadline: block.timestamp + 3 days,
            repaymentDeadline: block.timestamp + 33 days,
            namePrefix: "PMFI GUARD",
            symbolPrefix: "pGUARD"
        });
    }

    function _config(IERC20Metadata collateralToken, IERC20Metadata usdcToken)
        internal
        view
        returns (PMFIPositionConfigV21 memory config)
    {
        config = PMFIPositionConfigV21({
            factory: address(this),
            marketplace: address(this),
            borrower: borrower,
            collateral: collateralToken,
            usdc: usdcToken,
            collateralAmount: 100 * ONE,
            targetRaiseUsdc: 100e6,
            totalRepaymentUsdc: 120e6,
            fundingDeadline: block.timestamp + 3 days,
            repaymentDeadline: block.timestamp + 33 days,
            namePrefix: "PMFI DIRECT",
            symbolPrefix: "pDIRECT"
        });
    }

    function _expectCreateRevert(PMFIPositionFactoryV21.CreatePositionParams memory params, bytes4 selector) internal {
        vm.startPrank(borrower);
        vm.expectRevert(selector);

        factory.createPosition{value: CREATION_FEE}(params);

        vm.stopPrank();
    }

    function _create() internal returns (PMFIPositionVaultV21 vault, uint256 saleId) {
        PMFIPositionFactoryV21.CreatePositionParams memory params = _params(IERC20Metadata(address(collateral)));

        vm.startPrank(borrower);

        collateral.approve(address(factory), params.collateralAmount);

        (address vaultAddress, uint256 createdSaleId) = factory.createPosition{value: CREATION_FEE}(params);

        vm.stopPrank();

        vault = PMFIPositionVaultV21(vaultAddress);
        saleId = createdSaleId;
    }

    function test_FactoryConstructorAndAdminGuards() public {
        vm.expectRevert(PMFIPositionFactoryV21.ZeroAddress.selector);
        new PMFIPositionFactoryV21(IERC20Metadata(address(0)), feeRecipient, address(this));

        vm.expectRevert(PMFIPositionFactoryV21.ZeroAddress.selector);
        new PMFIPositionFactoryV21(IERC20Metadata(address(usdc)), address(0), address(this));
        bytes4 invalidOwnerSelector = bytes4(keccak256("OwnableInvalidOwner(address)"));

        vm.expectRevert(abi.encodeWithSelector(invalidOwnerSelector, address(0)));
        new PMFIPositionFactoryV21(IERC20Metadata(address(usdc)), feeRecipient, address(0));

        vm.expectRevert(PMFIPositionFactoryV21.NoCode.selector);
        new PMFIPositionFactoryV21(IERC20Metadata(attacker), feeRecipient, address(this));

        GuardToken badUsdc = new GuardToken("Bad USDC", "BUSDC", 18);

        vm.expectRevert(PMFIPositionFactoryV21.BadUsdcDecimals.selector);
        new PMFIPositionFactoryV21(IERC20Metadata(address(badUsdc)), feeRecipient, address(this));

        bytes4 unauthorizedSelector = bytes4(keccak256("OwnableUnauthorizedAccount(address)"));

        vm.startPrank(attacker);

        vm.expectRevert(abi.encodeWithSelector(unauthorizedSelector, attacker));
        factory.setPermissionlessCollateral(true);

        vm.stopPrank();

        factory.setPermissionlessCollateral(true);
        assertTrue(factory.permissionlessCollateral());

        factory.setPermissionlessCollateral(false);
        assertFalse(factory.permissionlessCollateral());

        vm.expectRevert(PMFIPositionFactoryV21.ZeroAddress.selector);
        factory.setCollateralAllowed(address(0), true);
    }

    function test_PermissionlessCollateralCanBeEnabledAndDisabled() public {
        GuardToken unlistedOne = new GuardToken("Unlisted One", "UNL1", 18);

        unlistedOne.mint(borrower, 100 * ONE);

        factory.setPermissionlessCollateral(true);

        PMFIPositionFactoryV21.CreatePositionParams memory params = _params(IERC20Metadata(address(unlistedOne)));

        vm.startPrank(borrower);

        unlistedOne.approve(address(factory), params.collateralAmount);

        (address vaultAddress,) = factory.createPosition{value: CREATION_FEE}(params);

        vm.stopPrank();

        assertTrue(factory.isVault(vaultAddress));

        factory.setPermissionlessCollateral(false);

        GuardToken unlistedTwo = new GuardToken("Unlisted Two", "UNL2", 18);

        unlistedTwo.mint(borrower, 100 * ONE);

        params = _params(IERC20Metadata(address(unlistedTwo)));

        vm.startPrank(borrower);

        unlistedTwo.approve(address(factory), params.collateralAmount);

        vm.expectRevert(PMFIPositionFactoryV21.CollateralNotAllowed.selector);

        factory.createPosition{value: CREATION_FEE}(params);

        vm.stopPrank();
    }

    function test_CreatePositionInputGuards() public {
        PMFIPositionFactoryV21.CreatePositionParams memory params;

        params = _params(IERC20Metadata(address(0)));
        _expectCreateRevert(params, PMFIPositionFactoryV21.ZeroAddress.selector);

        params = _params(IERC20Metadata(address(usdc)));
        _expectCreateRevert(params, PMFIPositionFactoryV21.SameTokens.selector);

        params = _params(IERC20Metadata(attacker));
        _expectCreateRevert(params, PMFIPositionFactoryV21.NoCode.selector);

        GuardToken excessiveDecimals = new GuardToken("Excessive Decimals", "XDEC", 31);

        factory.setCollateralAllowed(address(excessiveDecimals), true);

        params = _params(IERC20Metadata(address(excessiveDecimals)));
        _expectCreateRevert(params, PMFIPositionFactoryV21.BadCollateralDecimals.selector);

        params = _params(IERC20Metadata(address(collateral)));
        params.collateralAmount = 0;
        _expectCreateRevert(params, PMFIPositionFactoryV21.BadAmounts.selector);

        params = _params(IERC20Metadata(address(collateral)));
        params.targetRaiseUsdc = 0;
        _expectCreateRevert(params, PMFIPositionFactoryV21.BadAmounts.selector);

        params = _params(IERC20Metadata(address(collateral)));
        params.totalRepaymentUsdc = params.targetRaiseUsdc;
        _expectCreateRevert(params, PMFIPositionFactoryV21.BadAmounts.selector);

        params = _params(IERC20Metadata(address(collateral)));
        params.fundingDeadline = block.timestamp;
        _expectCreateRevert(params, PMFIPositionFactoryV21.BadDeadlines.selector);

        params = _params(IERC20Metadata(address(collateral)));
        params.fundingDeadline = block.timestamp + 30 minutes;
        _expectCreateRevert(params, PMFIPositionFactoryV21.BadDeadlines.selector);

        params = _params(IERC20Metadata(address(collateral)));
        params.fundingDeadline = block.timestamp + 31 days;
        params.repaymentDeadline = block.timestamp + 60 days;
        _expectCreateRevert(params, PMFIPositionFactoryV21.BadDeadlines.selector);

        params = _params(IERC20Metadata(address(collateral)));
        params.repaymentDeadline = params.fundingDeadline;
        _expectCreateRevert(params, PMFIPositionFactoryV21.BadDeadlines.selector);

        params = _params(IERC20Metadata(address(collateral)));
        params.repaymentDeadline = params.fundingDeadline + 366 days;
        _expectCreateRevert(params, PMFIPositionFactoryV21.BadDeadlines.selector);

        params = _params(IERC20Metadata(address(collateral)));
        params.namePrefix = "";
        _expectCreateRevert(params, PMFIPositionFactoryV21.BadPrefix.selector);

        params = _params(IERC20Metadata(address(collateral)));
        params.symbolPrefix = "";
        _expectCreateRevert(params, PMFIPositionFactoryV21.BadPrefix.selector);

        params = _params(IERC20Metadata(address(collateral)));
        params.namePrefix = string(new bytes(33));
        _expectCreateRevert(params, PMFIPositionFactoryV21.BadPrefix.selector);

        params = _params(IERC20Metadata(address(collateral)));
        params.symbolPrefix = string(new bytes(33));
        _expectCreateRevert(params, PMFIPositionFactoryV21.BadPrefix.selector);
    }

    function test_LegTokenAndVaultDirectGuards() public {
        vm.expectRevert(PMFILegTokenV21.ZeroAddress.selector);
        new PMFILegTokenV21("Invalid", "INV", 9, address(0), false);

        PMFILegTokenV21 token = new PMFILegTokenV21("Guard Leg", "GLEG", 9, address(this), false);

        assertEq(uint256(token.decimals()), 9);

        vm.startPrank(attacker);

        vm.expectRevert(PMFILegTokenV21.OnlyVault.selector);
        token.mint(attacker, ONE);

        vm.expectRevert(PMFILegTokenV21.OnlyVault.selector);
        token.burn(attacker, ONE);

        vm.expectRevert(PMFILegTokenV21.OnlyVault.selector);
        token.enableTransfers();

        vm.stopPrank();

        token.mint(borrower, ONE);

        vm.startPrank(borrower);

        vm.expectRevert(PMFILegTokenV21.TransfersDisabled.selector);
        token.transfer(lender, ONE);

        vm.stopPrank();

        PMFIPositionConfigV21 memory config =
            _config(IERC20Metadata(address(collateral)), IERC20Metadata(address(usdc)));

        config.factory = address(0);

        vm.expectRevert(PMFIPositionVaultV21.ZeroAddress.selector);
        new PMFIPositionVaultV21(config);

        config = _config(IERC20Metadata(address(usdc)), IERC20Metadata(address(usdc)));

        vm.expectRevert(PMFIPositionVaultV21.SameTokens.selector);
        new PMFIPositionVaultV21(config);

        config = _config(IERC20Metadata(address(collateral)), IERC20Metadata(address(usdc)));
        config.collateralAmount = 0;

        vm.expectRevert(PMFIPositionVaultV21.ZeroAmount.selector);
        new PMFIPositionVaultV21(config);

        config = _config(IERC20Metadata(address(collateral)), IERC20Metadata(address(usdc)));
        config.fundingDeadline = block.timestamp;

        vm.expectRevert(PMFIPositionVaultV21.BadDeadlines.selector);
        new PMFIPositionVaultV21(config);

        GuardToken excessiveDecimals = new GuardToken("Excessive Decimals", "XDEC", 31);

        config = _config(IERC20Metadata(address(excessiveDecimals)), IERC20Metadata(address(usdc)));

        vm.expectRevert(PMFIPositionVaultV21.BadDecimals.selector);
        new PMFIPositionVaultV21(config);

        config = _config(IERC20Metadata(address(collateral)), IERC20Metadata(address(usdc)));

        PMFIPositionVaultV21 vault = new PMFIPositionVaultV21(config);

        vm.startPrank(attacker);

        vm.expectRevert(PMFIPositionVaultV21.OnlyFactory.selector);
        vault.initializePosition();

        vm.expectRevert(PMFIPositionVaultV21.OnlyMarketplace.selector);
        vault.closeFunding(0);

        vm.stopPrank();

        vm.expectRevert(PMFIPositionVaultV21.InsufficientCollateral.selector);
        vault.initializePosition();

        collateral.transfer(address(vault), 100 * ONE);

        vault.initializePosition();

        vm.expectRevert(PMFIPositionVaultV21.AlreadyInitialized.selector);
        vault.initializePosition();
    }

    function test_MarketplaceViewsAndClosureGuards() public {
        (PMFIPositionVaultV21 vault, uint256 saleId) = _create();

        assertEq(marketplace.salesLength(), 1);
        assertEq(uint256(vault.P().decimals()), 18);
        assertEq(uint256(vault.N().decimals()), 18);

        assertEq(marketplace.quoteUsdc(saleId, 40 * ONE), 40e6);

        assertEq(marketplace.quoteFee(saleId, 40e6), 40_000);

        vm.expectRevert(PMFIPrimaryMarketplaceV21.ZeroAmount.selector);
        marketplace.quoteUsdc(saleId, 0);

        vm.expectRevert(PMFIPrimaryMarketplaceV21.TooMuch.selector);
        marketplace.quoteUsdc(saleId, 100 * ONE + 1);

        (,, uint256 totalPayment) = marketplace.quoteTotalPayment(saleId, 10 * ONE);

        vm.prank(lender);
        vm.expectRevert(PMFIPrimaryMarketplaceV21.MaxPaymentExceeded.selector);
        marketplace.buy(saleId, 10 * ONE, totalPayment - 1);

        vm.prank(lender);
        vm.expectRevert(PMFIPrimaryMarketplaceV21.NotSeller.selector);
        marketplace.cancel(saleId);

        vm.expectRevert(PMFIPrimaryMarketplaceV21.BadExpiry.selector);
        marketplace.closeExpired(saleId);

        vm.warp(vault.fundingDeadline());

        vm.prank(lender);
        vm.expectRevert(PMFIPrimaryMarketplaceV21.SaleExpired.selector);
        marketplace.buy(saleId, ONE, type(uint256).max);

        marketplace.closeExpired(saleId);

        vm.expectRevert(PMFIPrimaryMarketplaceV21.NotActive.selector);
        marketplace.closeExpired(saleId);

        vm.prank(borrower);
        vm.expectRevert(PMFIPrimaryMarketplaceV21.NotActive.selector);
        marketplace.cancel(saleId);

        vm.prank(lender);
        vm.expectRevert(PMFIPrimaryMarketplaceV21.NotActive.selector);
        marketplace.buy(saleId, ONE, type(uint256).max);
    }

    function test_VaultLifecycleAndPreviewGuards() public {
        PMFIPositionConfigV21 memory config =
            _config(IERC20Metadata(address(collateral)), IERC20Metadata(address(usdc)));

        PMFIPositionVaultV21 vault = new PMFIPositionVaultV21(config);

        collateral.transfer(address(vault), 100 * ONE);

        vault.initializePosition();
        vault.closeFunding(0);

        vm.expectRevert(PMFIPositionVaultV21.AlreadyFundingClosed.selector);
        vault.closeFunding(0);

        vm.startPrank(borrower);

        vm.expectRevert(PMFIPositionVaultV21.ZeroAmount.selector);
        vault.redeemPair(0);

        vm.expectRevert(PMFIPositionVaultV21.ZeroAmount.selector);
        vault.exercise(0);

        vm.expectRevert(PMFIPositionVaultV21.ExerciseAmountTooSmall.selector);
        vault.exercise(1);

        vm.stopPrank();

        vm.expectRevert(PMFIPositionVaultV21.NotSettled.selector);
        vault.previewRedeemP(ONE);

        vm.warp(vault.repaymentDeadline() + 1);

        vault.settle();

        vm.expectRevert(PMFIPositionVaultV21.AlreadySettled.selector);
        vault.settle();

        vm.prank(borrower);
        vm.expectRevert(PMFIPositionVaultV21.AlreadySettled.selector);
        vault.exercise(ONE);

        vm.expectRevert(PMFIPositionVaultV21.AlreadySettled.selector);
        vault.closeFunding(0);

        vm.expectRevert(PMFIPositionVaultV21.ZeroAmount.selector);
        vault.previewRedeemP(0);

        (uint256 collateralOut, uint256 usdcOut) = vault.previewRedeemP(50 * ONE);

        assertEq(collateralOut, 50 * ONE);
        assertEq(usdcOut, 0);

        vault.redeemP(50 * ONE);

        (collateralOut, usdcOut) = vault.previewRedeemP(50 * ONE);

        assertEq(collateralOut, 50 * ONE);
        assertEq(usdcOut, 0);

        vault.redeemP(50 * ONE);

        vm.expectRevert(PMFIPositionVaultV21.NoPSupply.selector);
        vault.previewRedeemP(1);
    }

    function test_CloseWithoutOutstandingP() public {
        PMFIPositionConfigV21 memory config =
            _config(IERC20Metadata(address(collateral)), IERC20Metadata(address(usdc)));

        PMFIPositionVaultV21 vault = new PMFIPositionVaultV21(config);

        collateral.transfer(address(vault), 100 * ONE);

        vault.initializePosition();
        vault.closeFunding(100 * ONE);

        assertTrue(vault.fundingClosed());
        assertTrue(vault.closedWithoutOutstandingP());
        assertEq(vault.P().totalSupply(), 0);
        assertEq(vault.N().totalSupply(), 0);
        assertEq(vault.usdcOwed(0), 0);
        assertEq(vault.usdcOwed(1), 0);

        vm.warp(vault.repaymentDeadline() + 1);

        vm.expectRevert(PMFIPositionVaultV21.NoPSupply.selector);
        vault.settle();
    }

    function test_EmptyFeeAndRegistrationGuards() public {
        vm.startPrank(feeRecipient);

        vm.expectRevert(PMFIPositionFactoryV21.NoFees.selector);
        factory.withdrawCreationFees();

        vm.expectRevert(PMFIPrimaryMarketplaceV21.NoFees.selector);
        marketplace.withdrawProtocolFees();

        vm.stopPrank();

        vm.prank(attacker);
        vm.expectRevert(PMFIPrimaryMarketplaceV21.OnlyFactory.selector);
        marketplace.registerPrimarySale(address(0));

        vm.expectRevert(PMFIPrimaryMarketplaceV21.UnverifiedVault.selector);
        new PMFIPrimaryMarketplaceV21(address(0), IERC20Metadata(address(usdc)), feeRecipient);

        PMFIPrimaryMarketplaceV21 localMarketplace =
            new PMFIPrimaryMarketplaceV21(address(this), IERC20Metadata(address(usdc)), feeRecipient);

        vm.expectRevert(PMFIPrimaryMarketplaceV21.UnverifiedVault.selector);
        localMarketplace.registerPrimarySale(address(0));
    }

    function test_RejectingEthRecipientCannotWithdraw() public {
        GuardToken localUsdc = new GuardToken("Local USD", "LUSD", 6);

        GuardToken localCollateral = new GuardToken("Local Collateral", "LCOL", 18);

        RejectEthRecipient rejectingRecipient = new RejectEthRecipient();

        PMFIPositionFactoryV21 localFactory =
            new PMFIPositionFactoryV21(IERC20Metadata(address(localUsdc)), address(rejectingRecipient), address(this));

        localFactory.setCollateralAllowed(address(localCollateral), true);

        localCollateral.mint(borrower, 100 * ONE);

        PMFIPositionFactoryV21.CreatePositionParams memory params = PMFIPositionFactoryV21.CreatePositionParams({
            collateral: IERC20Metadata(address(localCollateral)),
            collateralAmount: 100 * ONE,
            targetRaiseUsdc: 100e6,
            totalRepaymentUsdc: 120e6,
            fundingDeadline: block.timestamp + 3 days,
            repaymentDeadline: block.timestamp + 33 days,
            namePrefix: "PMFI REJECT",
            symbolPrefix: "pREJECT"
        });

        vm.startPrank(borrower);

        localCollateral.approve(address(localFactory), 100 * ONE);

        localFactory.createPosition{value: localFactory.CREATION_FEE()}(params);

        vm.stopPrank();

        assertEq(address(localFactory).balance, localFactory.CREATION_FEE());

        vm.expectRevert(PMFIPositionFactoryV21.EthTransferFailed.selector);
        rejectingRecipient.withdraw(localFactory);

        assertEq(address(localFactory).balance, localFactory.CREATION_FEE());
    }

    function test_RedeemPairCanCloseAllOutstandingClaims() public {
        PMFIPositionConfigV21 memory config =
            _config(IERC20Metadata(address(collateral)), IERC20Metadata(address(usdc)));

        PMFIPositionVaultV21 vault = new PMFIPositionVaultV21(config);

        collateral.transfer(address(vault), 100 * ONE);

        vault.initializePosition();
        vault.closeFunding(0);

        vault.P().transfer(borrower, 100 * ONE);

        uint256 borrowerCollateralBefore = collateral.balanceOf(borrower);

        vm.prank(borrower);
        vault.redeemPair(100 * ONE);

        assertTrue(vault.closedWithoutOutstandingP());
        assertEq(vault.P().totalSupply(), 0);
        assertEq(vault.N().totalSupply(), 0);

        assertEq(collateral.balanceOf(borrower), borrowerCollateralBefore + 100 * ONE);
    }

    function test_RedeemPairRejectsAfterSettlement() public {
        PMFIPositionConfigV21 memory config =
            _config(IERC20Metadata(address(collateral)), IERC20Metadata(address(usdc)));

        PMFIPositionVaultV21 vault = new PMFIPositionVaultV21(config);

        collateral.transfer(address(vault), 100 * ONE);

        vault.initializePosition();
        vault.closeFunding(0);

        vm.warp(vault.repaymentDeadline() + 1);
        vault.settle();

        vm.prank(borrower);
        vm.expectRevert(PMFIPositionVaultV21.AlreadySettled.selector);
        vault.redeemPair(ONE);
    }
}
