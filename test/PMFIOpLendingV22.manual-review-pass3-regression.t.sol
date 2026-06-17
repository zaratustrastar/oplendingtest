// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {PMFIPositionFactoryV22, PMFIPositionVaultV22, PMFIPrimaryMarketplaceV22} from "../src/PMFIOpLendingV22.sol";

contract V22Pass3SenderSurchargeToken is ERC20 {
    uint8 private immutable _tokenDecimals;

    address public surchargeSender;
    uint256 public surchargeBps;
    bool public surchargeEnabled;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    function mint(address recipient, uint256 amount) external {
        _mint(recipient, amount);
    }

    function configureSenderSurcharge(address sender, uint256 bps, bool enabled) external {
        surchargeSender = sender;
        surchargeBps = bps;
        surchargeEnabled = enabled;
    }

    function _update(address from, address to, uint256 amount) internal override {
        bool applySurcharge = surchargeEnabled && from != address(0) && to != address(0) && from == surchargeSender;

        if (!applySurcharge) {
            super._update(from, to, amount);
            return;
        }

        super._update(from, to, amount);

        uint256 surcharge = amount * surchargeBps / 10_000;

        if (surcharge != 0) {
            super._update(from, address(0), surcharge);
        }
    }
}

contract PMFIOpLendingV22ManualReviewPass3RegressionTest is TestBase {
    uint256 internal constant ONE = 1e18;

    uint256 internal constant COLLATERAL_AMOUNT = 100 * ONE;

    uint256 internal constant TARGET_RAISE = 100e6;

    uint256 internal constant TOTAL_REPAYMENT = 120e6;

    address internal borrower = makeAddr("v22Pass3Borrower");

    address internal lender = makeAddr("v22Pass3Lender");

    address internal feeRecipient = makeAddr("v22Pass3FeeRecipient");

    V22Pass3SenderSurchargeToken internal usdc;
    V22Pass3SenderSurchargeToken internal collateral;

    PMFIPositionFactoryV22 internal factory;
    PMFIPrimaryMarketplaceV22 internal marketplace;
    PMFIPositionVaultV22 internal vault;

    uint256 internal saleId;

    function setUp() public {
        usdc = new V22Pass3SenderSurchargeToken("USD Coin", "USDC", 6);

        collateral = new V22Pass3SenderSurchargeToken("Collateral", "COL", 18);

        factory = new PMFIPositionFactoryV22(IERC20Metadata(address(usdc)), feeRecipient, address(this));

        marketplace = PMFIPrimaryMarketplaceV22(factory.marketplace());

        factory.setCollateralAllowed(address(collateral), true);

        collateral.mint(borrower, 1_000 * ONE);

        usdc.mint(borrower, 1_000e6);

        usdc.mint(lender, 1_000e6);

        vm.deal(borrower, 10 ether);
    }

    function _params() internal view returns (PMFIPositionFactoryV22.CreatePositionParams memory params) {
        params = PMFIPositionFactoryV22.CreatePositionParams({
            collateral: IERC20Metadata(address(collateral)),
            collateralAmount: COLLATERAL_AMOUNT,
            targetRaiseUsdc: TARGET_RAISE,
            totalRepaymentUsdc: TOTAL_REPAYMENT,
            fundingDeadline: block.timestamp + 3 days,
            repaymentDeadline: block.timestamp + 33 days,
            namePrefix: "V22 PASS3",
            symbolPrefix: "V22P3"
        });
    }

    function _createPosition() internal {
        uint256 creationFee = factory.CREATION_FEE();

        vm.startPrank(borrower);

        collateral.approve(address(factory), type(uint256).max);

        (address vaultAddress, uint256 createdSaleId) = factory.createPosition{value: creationFee}(_params());

        vm.stopPrank();

        vault = PMFIPositionVaultV22(vaultAddress);

        saleId = createdSaleId;
    }

    function _tryCreatePosition() internal returns (bool created) {
        uint256 creationFee = factory.CREATION_FEE();

        PMFIPositionFactoryV22.CreatePositionParams memory params = _params();

        vm.startPrank(borrower);

        collateral.approve(address(factory), type(uint256).max);

        (created,) = address(factory).call{value: creationFee}(
            abi.encodeWithSelector(PMFIPositionFactoryV22.createPosition.selector, params)
        );

        vm.stopPrank();
    }

    function _quoteFullPurchase() internal view returns (uint256 sellerPrice, uint256 feeAmount, uint256 totalPayment) {
        return marketplace.quoteTotalPayment(saleId, COLLATERAL_AMOUNT);
    }

    function _tryFullPurchase(uint256 totalPayment) internal returns (bool purchased) {
        vm.startPrank(lender);

        usdc.approve(address(marketplace), type(uint256).max);

        (purchased,) = address(marketplace)
            .call(
                abi.encodeWithSelector(PMFIPrimaryMarketplaceV22.buy.selector, saleId, COLLATERAL_AMOUNT, totalPayment)
            );

        vm.stopPrank();
    }

    function _buyFullNormally() internal {
        (,, uint256 totalPayment) = _quoteFullPurchase();

        vm.startPrank(lender);

        usdc.approve(address(marketplace), type(uint256).max);

        marketplace.buy(saleId, COLLATERAL_AMOUNT, totalPayment);

        vm.stopPrank();
    }

    function _tryRepayInFull(uint256 required) internal returns (bool repaid) {
        vm.startPrank(borrower);

        usdc.approve(address(vault), type(uint256).max);

        (repaid,) = address(vault).call(abi.encodeWithSelector(PMFIPositionVaultV22.repayInFull.selector));

        vm.stopPrank();

        required;
    }

    function test_CollateralSenderSurchargeCannotOverchargeBorrowerOrCreatePosition() public {
        uint256 borrowerBefore = collateral.balanceOf(borrower);

        collateral.configureSenderSurcharge(borrower, 100, true);

        bool created = _tryCreatePosition();

        assertFalse(created);

        assertEq(collateral.balanceOf(borrower), borrowerBefore);

        assertEq(factory.allVaultsLength(), 0);

        assertEq(address(factory).balance, 0);

        collateral.configureSenderSurcharge(borrower, 0, false);

        _createPosition();

        assertEq(borrowerBefore - collateral.balanceOf(borrower), COLLATERAL_AMOUNT);

        assertEq(collateral.balanceOf(address(vault)), COLLATERAL_AMOUNT);

        assertEq(vault.accountedCollateral(), COLLATERAL_AMOUNT);

        assertEq(vault.P().totalSupply(), COLLATERAL_AMOUNT);

        assertEq(vault.N().totalSupply(), COLLATERAL_AMOUNT);
    }

    function test_BuyerUsdcSenderSurchargeCannotOverchargeBuyerOrAdvanceSale() public {
        _createPosition();

        (, uint256 feeAmount, uint256 totalPayment) = _quoteFullPurchase();

        uint256 lenderBefore = usdc.balanceOf(lender);

        usdc.configureSenderSurcharge(lender, 100, true);

        bool purchased = _tryFullPurchase(totalPayment);

        assertFalse(purchased);

        assertEq(usdc.balanceOf(lender), lenderBefore);

        assertEq(vault.P().balanceOf(lender), 0);

        assertEq(vault.P().balanceOf(address(marketplace)), COLLATERAL_AMOUNT);

        assertEq(marketplace.accruedProtocolFees(), 0);

        assertFalse(vault.fundingClosed());

        usdc.configureSenderSurcharge(lender, 0, false);

        _buyFullNormally();

        assertEq(lenderBefore - usdc.balanceOf(lender), totalPayment);

        assertEq(marketplace.accruedProtocolFees(), feeAmount);
    }

    function test_RepaymentUsdcSenderSurchargeCannotOverchargeBorrowerOrRepay() public {
        _createPosition();
        _buyFullNormally();

        uint256 required = vault.repaymentRequiredUsdc();

        uint256 borrowerUsdcBefore = usdc.balanceOf(borrower);

        uint256 borrowerCollateralBefore = collateral.balanceOf(borrower);

        uint256 borrowerNBefore = vault.N().balanceOf(borrower);

        usdc.configureSenderSurcharge(borrower, 100, true);

        bool repaid = _tryRepayInFull(required);

        assertFalse(repaid);

        assertEq(usdc.balanceOf(borrower), borrowerUsdcBefore);

        assertEq(collateral.balanceOf(borrower), borrowerCollateralBefore);

        assertEq(vault.N().balanceOf(borrower), borrowerNBefore);

        assertEq(vault.usdcPaid(), 0);

        usdc.configureSenderSurcharge(borrower, 0, false);

        vm.startPrank(borrower);

        usdc.approve(address(vault), type(uint256).max);

        vault.repayInFull();

        vm.stopPrank();

        assertEq(borrowerUsdcBefore - usdc.balanceOf(borrower), required);

        assertEq(collateral.balanceOf(borrower) - borrowerCollateralBefore, COLLATERAL_AMOUNT);

        assertEq(vault.usdcPaid(), required);
    }
}
