// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {PMFIPositionFactoryV22, PMFIPositionVaultV22, PMFIPrimaryMarketplaceV22} from "../src/PMFIOpLendingV22.sol";

contract V22BinaryToken is ERC20 {
    uint8 private immutable _tokenDecimals;

    address public blockedSender;
    bool public outboundBlocked;

    error OutboundBlocked();

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function configureOutboundBlock(address sender, bool blocked) external {
        blockedSender = sender;
        outboundBlocked = blocked;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (outboundBlocked && from == blockedSender && from != address(0) && to != address(0)) {
            revert OutboundBlocked();
        }

        super._update(from, to, value);
    }
}

contract PMFIOpLendingV22BinarySettlementRegressionTest is TestBase {
    uint256 internal constant ONE = 1e18;
    uint256 internal constant COLLATERAL_AMOUNT = 100 * ONE;
    uint256 internal constant USDC_DONATION = 7e6;
    uint256 internal constant COLLATERAL_DONATION = 7 * ONE;

    V22BinaryToken internal usdc;
    V22BinaryToken internal collateral;

    PMFIPositionFactoryV22 internal factory;
    PMFIPrimaryMarketplaceV22 internal marketplace;

    address internal borrower = makeAddr("v22BinaryBorrower");
    address internal lender1 = makeAddr("v22BinaryLender1");
    address internal lender2 = makeAddr("v22BinaryLender2");
    address internal donor = makeAddr("v22BinaryDonor");
    address internal feeRecipient = makeAddr("v22BinaryFees");

    function setUp() public {
        usdc = new V22BinaryToken("USD Coin", "USDC", 6);
        collateral = new V22BinaryToken("V2.2 Binary Collateral", "V22BIN", 18);

        factory = new PMFIPositionFactoryV22(IERC20Metadata(address(usdc)), feeRecipient, address(this));

        marketplace = PMFIPrimaryMarketplaceV22(factory.marketplace());

        factory.setCollateralAllowed(address(collateral), true);

        collateral.mint(borrower, 1_000 * ONE);
        collateral.mint(donor, 100 * ONE);

        usdc.mint(borrower, 1_000e6);
        usdc.mint(lender1, 1_000e6);
        usdc.mint(lender2, 1_000e6);
        usdc.mint(donor, 100e6);

        vm.deal(borrower, 1 ether);
    }

    function _create() internal returns (PMFIPositionVaultV22 vault, uint256 saleId) {
        PMFIPositionFactoryV22.CreatePositionParams memory params = PMFIPositionFactoryV22.CreatePositionParams({
            collateral: IERC20Metadata(address(collateral)),
            collateralAmount: COLLATERAL_AMOUNT,
            targetRaiseUsdc: 100e6,
            totalRepaymentUsdc: 120e6,
            fundingDeadline: block.timestamp + 3 days,
            repaymentDeadline: block.timestamp + 33 days,
            namePrefix: "V22 BINARY",
            symbolPrefix: "V22BIN"
        });

        vm.startPrank(borrower);

        collateral.approve(address(factory), COLLATERAL_AMOUNT);

        (address vaultAddress, uint256 createdSaleId) = factory.createPosition{value: factory.CREATION_FEE()}(params);

        vm.stopPrank();

        vault = PMFIPositionVaultV22(vaultAddress);
        saleId = createdSaleId;
    }

    function _buy(uint256 saleId, address buyer, uint256 amount) internal {
        (,, uint256 totalPayment) = marketplace.quoteTotalPayment(saleId, amount);

        vm.startPrank(buyer);

        usdc.approve(address(marketplace), totalPayment);

        marketplace.buy(saleId, amount, totalPayment);

        vm.stopPrank();
    }

    function _repayInFull(PMFIPositionVaultV22 vault) internal returns (uint256 required) {
        required = vault.repaymentRequiredUsdc();

        vm.startPrank(borrower);

        usdc.approve(address(vault), required);
        vault.repayInFull();

        vm.stopPrank();
    }

    function _donateUsdc(PMFIPositionVaultV22 vault) internal {
        vm.prank(donor);

        assertTrue(usdc.transfer(address(vault), USDC_DONATION));
    }

    function test_FullRepaymentSettlementIgnoresPreSettlementUsdcDonation() public {
        (PMFIPositionVaultV22 vault, uint256 saleId) = _create();

        _buy(saleId, lender1, COLLATERAL_AMOUNT);
        _donateUsdc(vault);

        uint256 required = _repayInFull(vault);

        vault.settle();

        assertEq(vault.collateralPoolAtSettle(), 0);
        assertEq(vault.usdcPoolAtSettle(), required);

        // The raw balance includes the donation, but claims must not.
        assertEq(usdc.balanceOf(address(vault)), required + USDC_DONATION);
    }

    function test_DefaultSettlementIsCollateralOnlyDespiteUsdcDonation() public {
        (PMFIPositionVaultV22 vault, uint256 saleId) = _create();

        _buy(saleId, lender1, COLLATERAL_AMOUNT);
        _donateUsdc(vault);

        vm.warp(vault.repaymentDeadline() + 1);
        vault.settle();

        assertEq(vault.collateralPoolAtSettle(), COLLATERAL_AMOUNT);

        assertEq(vault.usdcPoolAtSettle(), 0);
    }

    function test_PostSettlementUsdcDonationDoesNotIncreaseFinalRedemption() public {
        (PMFIPositionVaultV22 vault, uint256 saleId) = _create();

        _buy(saleId, lender1, COLLATERAL_AMOUNT);

        uint256 required = _repayInFull(vault);

        vault.settle();
        _donateUsdc(vault);

        uint256 lenderBefore = usdc.balanceOf(lender1);

        vm.prank(lender1);
        vault.redeemP(COLLATERAL_AMOUNT);

        assertEq(usdc.balanceOf(lender1) - lenderBefore, required);

        assertEq(usdc.balanceOf(address(vault)), USDC_DONATION);
    }

    function test_SplitRedemptionsUseTrackedUsdcPoolAndLeaveDonation() public {
        (PMFIPositionVaultV22 vault, uint256 saleId) = _create();

        _buy(saleId, lender1, COLLATERAL_AMOUNT);

        address pToken = address(vault.P());

        vm.prank(lender1);

        (bool transferred, bytes memory returnData) =
            pToken.call(abi.encodeWithSignature("transfer(address,uint256)", lender2, 60 * ONE));

        assertTrue(transferred);
        assertTrue(abi.decode(returnData, (bool)));

        uint256 required = _repayInFull(vault);
        assertEq(required, 120e6);

        vault.settle();
        _donateUsdc(vault);

        uint256 lender1Before = usdc.balanceOf(lender1);
        uint256 lender2Before = usdc.balanceOf(lender2);

        vm.prank(lender1);
        vault.redeemP(40 * ONE);

        vm.prank(lender2);
        vault.redeemP(60 * ONE);

        assertEq(usdc.balanceOf(lender1) - lender1Before, 48e6);

        assertEq(usdc.balanceOf(lender2) - lender2Before, 72e6);

        assertEq(usdc.balanceOf(address(vault)), USDC_DONATION);
    }

    function test_PostSettlementCollateralDonationDoesNotIncreaseDefaultRedemption() public {
        (PMFIPositionVaultV22 vault, uint256 saleId) = _create();

        _buy(saleId, lender1, COLLATERAL_AMOUNT);

        vm.warp(vault.repaymentDeadline() + 1);
        vault.settle();

        vm.prank(donor);

        assertTrue(collateral.transfer(address(vault), COLLATERAL_DONATION));

        uint256 lenderBefore = collateral.balanceOf(lender1);

        vm.prank(lender1);
        vault.redeemP(COLLATERAL_AMOUNT);

        assertEq(collateral.balanceOf(lender1) - lenderBefore, COLLATERAL_AMOUNT);

        assertEq(collateral.balanceOf(address(vault)), COLLATERAL_DONATION);
    }

    function test_FullyRepaidRedemptionNeverTouchesCollateral() public {
        (PMFIPositionVaultV22 vault, uint256 saleId) = _create();

        _buy(saleId, lender1, COLLATERAL_AMOUNT);

        uint256 required = _repayInFull(vault);

        collateral.configureOutboundBlock(address(vault), true);

        vault.settle();

        uint256 lenderBefore = usdc.balanceOf(lender1);

        vm.prank(lender1);
        vault.redeemP(COLLATERAL_AMOUNT);

        assertEq(usdc.balanceOf(lender1) - lenderBefore, required);

        assertEq(collateral.balanceOf(lender1), 0);
    }
}
