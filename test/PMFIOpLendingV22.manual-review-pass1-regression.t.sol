// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {PMFIPositionFactoryV22, PMFIPositionVaultV22, PMFIPrimaryMarketplaceV22} from "../src/PMFIOpLendingV22.sol";

contract V22SwitchableFeeToken is ERC20 {
    uint8 private immutable _tokenDecimals;

    bool public feeEnabled;
    uint256 public feeBps = 100;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFeeEnabled(bool enabled) external {
        feeEnabled = enabled;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (feeEnabled && from != address(0) && to != address(0)) {
            uint256 fee = amount * feeBps / 10_000;

            if (fee != 0) {
                super._update(from, address(0), fee);
                super._update(from, to, amount - fee);
                return;
            }
        }

        super._update(from, to, amount);
    }
}

contract PMFIOpLendingV22ManualReviewPass1RegressionTest is TestBase {
    uint256 internal constant ONE = 1e18;
    uint256 internal constant COLLATERAL_AMOUNT = 100 * ONE;
    uint256 internal constant TARGET_RAISE = 100e6;
    uint256 internal constant TOTAL_REPAYMENT = 120e6;

    address internal borrower = makeAddr("v22Pass1Borrower");
    address internal lender = makeAddr("v22Pass1Lender");
    address internal feeRecipient = makeAddr("v22Pass1Fees");

    function _deployAndCreate(V22SwitchableFeeToken usdc, V22SwitchableFeeToken collateral)
        internal
        returns (
            PMFIPositionFactoryV22 factory,
            PMFIPrimaryMarketplaceV22 marketplace,
            PMFIPositionVaultV22 vault,
            uint256 saleId
        )
    {
        factory = new PMFIPositionFactoryV22(IERC20Metadata(address(usdc)), feeRecipient, address(this));

        marketplace = PMFIPrimaryMarketplaceV22(factory.marketplace());

        factory.setCollateralAllowed(address(collateral), true);

        collateral.mint(borrower, COLLATERAL_AMOUNT);
        usdc.mint(borrower, 1_000e6);
        usdc.mint(lender, 1_000e6);

        vm.deal(borrower, 10 ether);

        PMFIPositionFactoryV22.CreatePositionParams memory params = PMFIPositionFactoryV22.CreatePositionParams({
            collateral: IERC20Metadata(address(collateral)),
            collateralAmount: COLLATERAL_AMOUNT,
            targetRaiseUsdc: TARGET_RAISE,
            totalRepaymentUsdc: TOTAL_REPAYMENT,
            fundingDeadline: block.timestamp + 3 days,
            repaymentDeadline: block.timestamp + 33 days,
            namePrefix: "V22 PASS1",
            symbolPrefix: "V22P1"
        });

        vm.startPrank(borrower);

        collateral.approve(address(factory), COLLATERAL_AMOUNT);

        (address vaultAddress, uint256 createdSaleId) = factory.createPosition{value: factory.CREATION_FEE()}(params);

        vm.stopPrank();

        vault = PMFIPositionVaultV22(vaultAddress);
        saleId = createdSaleId;
    }

    function _buyFull(PMFIPrimaryMarketplaceV22 marketplace, V22SwitchableFeeToken usdc, uint256 saleId) internal {
        (,, uint256 totalPayment) = marketplace.quoteTotalPayment(saleId, COLLATERAL_AMOUNT);

        vm.startPrank(lender);

        usdc.approve(address(marketplace), totalPayment);

        marketplace.buy(saleId, COLLATERAL_AMOUNT, totalPayment);

        vm.stopPrank();
    }

    function test_PostCreationFeeCannotUnderpayPairRedemption() public {
        V22SwitchableFeeToken usdc = new V22SwitchableFeeToken("USD Coin", "USDC", 6);

        V22SwitchableFeeToken collateral = new V22SwitchableFeeToken("Collateral", "COL", 18);

        (, PMFIPrimaryMarketplaceV22 marketplace, PMFIPositionVaultV22 vault, uint256 saleId) =
            _deployAndCreate(usdc, collateral);

        _buyFull(marketplace, usdc, saleId);

        uint256 pairAmount = 20 * ONE;

        ERC20 pToken = ERC20(address(vault.P()));

        vm.prank(lender);
        assertTrue(pToken.transfer(borrower, pairAmount));

        uint256 borrowerPBefore = vault.P().balanceOf(borrower);
        uint256 borrowerNBefore = vault.N().balanceOf(borrower);
        uint256 borrowerCollateralBefore = collateral.balanceOf(borrower);
        uint256 accountedBefore = vault.accountedCollateral();

        collateral.setFeeEnabled(true);

        vm.prank(borrower);

        (bool redeemed,) =
            address(vault).call(abi.encodeWithSelector(PMFIPositionVaultV22.redeemPair.selector, pairAmount));

        assertFalse(redeemed);

        assertEq(vault.P().balanceOf(borrower), borrowerPBefore);
        assertEq(vault.N().balanceOf(borrower), borrowerNBefore);
        assertEq(collateral.balanceOf(borrower), borrowerCollateralBefore);
        assertEq(vault.accountedCollateral(), accountedBefore);

        collateral.setFeeEnabled(false);

        vm.prank(borrower);
        vault.redeemPair(pairAmount);

        assertEq(collateral.balanceOf(borrower) - borrowerCollateralBefore, pairAmount);
    }

    function test_PostCreationFeeCannotUnderpayDefaultRedemption() public {
        V22SwitchableFeeToken usdc = new V22SwitchableFeeToken("USD Coin", "USDC", 6);

        V22SwitchableFeeToken collateral = new V22SwitchableFeeToken("Collateral", "COL", 18);

        (, PMFIPrimaryMarketplaceV22 marketplace, PMFIPositionVaultV22 vault, uint256 saleId) =
            _deployAndCreate(usdc, collateral);

        _buyFull(marketplace, usdc, saleId);

        vm.warp(vault.repaymentDeadline() + 1);
        vault.settle();

        uint256 lenderPBefore = vault.P().balanceOf(lender);
        uint256 lenderCollateralBefore = collateral.balanceOf(lender);
        uint256 accountedBefore = vault.accountedCollateral();

        collateral.setFeeEnabled(true);

        vm.prank(lender);

        (bool redeemed,) =
            address(vault).call(abi.encodeWithSelector(PMFIPositionVaultV22.redeemP.selector, COLLATERAL_AMOUNT));

        assertFalse(redeemed);

        assertEq(vault.P().balanceOf(lender), lenderPBefore);
        assertEq(collateral.balanceOf(lender), lenderCollateralBefore);
        assertEq(vault.accountedCollateral(), accountedBefore);

        collateral.setFeeEnabled(false);

        vm.prank(lender);
        vault.redeemP(COLLATERAL_AMOUNT);

        assertEq(collateral.balanceOf(lender) - lenderCollateralBefore, COLLATERAL_AMOUNT);
    }

    function test_PostRepaymentFeeCannotUnderpayUsdcRedemption() public {
        V22SwitchableFeeToken usdc = new V22SwitchableFeeToken("USD Coin", "USDC", 6);

        V22SwitchableFeeToken collateral = new V22SwitchableFeeToken("Collateral", "COL", 18);

        (, PMFIPrimaryMarketplaceV22 marketplace, PMFIPositionVaultV22 vault, uint256 saleId) =
            _deployAndCreate(usdc, collateral);

        _buyFull(marketplace, usdc, saleId);

        uint256 required = vault.repaymentRequiredUsdc();

        vm.startPrank(borrower);

        usdc.approve(address(vault), required);
        vault.repayInFull();

        vm.stopPrank();

        vault.settle();

        uint256 lenderPBefore = vault.P().balanceOf(lender);
        uint256 lenderUsdcBefore = usdc.balanceOf(lender);
        uint256 poolBefore = vault.usdcPoolRemaining();

        usdc.setFeeEnabled(true);

        vm.prank(lender);

        (bool redeemed,) =
            address(vault).call(abi.encodeWithSelector(PMFIPositionVaultV22.redeemP.selector, COLLATERAL_AMOUNT));

        assertFalse(redeemed);

        assertEq(vault.P().balanceOf(lender), lenderPBefore);
        assertEq(usdc.balanceOf(lender), lenderUsdcBefore);
        assertEq(vault.usdcPoolRemaining(), poolBefore);

        usdc.setFeeEnabled(false);

        vm.prank(lender);
        vault.redeemP(COLLATERAL_AMOUNT);

        assertEq(usdc.balanceOf(lender) - lenderUsdcBefore, required);
    }

    function test_StrictAllowlistOwnerCannotRenounceOwnership() public {
        V22SwitchableFeeToken usdc = new V22SwitchableFeeToken("USD Coin", "USDC", 6);

        PMFIPositionFactoryV22 factory =
            new PMFIPositionFactoryV22(IERC20Metadata(address(usdc)), feeRecipient, address(this));

        address ownerBefore = factory.owner();

        (bool renounced,) = address(factory).call(abi.encodeWithSignature("renounceOwnership()"));

        assertFalse(renounced);
        assertEq(factory.owner(), ownerBefore);

        V22SwitchableFeeToken collateral = new V22SwitchableFeeToken("Collateral", "COL", 18);

        factory.setCollateralAllowed(address(collateral), true);

        assertTrue(factory.collateralAllowed(address(collateral)));
    }
}
