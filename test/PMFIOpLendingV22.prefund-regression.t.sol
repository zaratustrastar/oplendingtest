// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {PMFIPositionFactoryV22, PMFIPositionVaultV22, PMFIPrimaryMarketplaceV22} from "../src/PMFIOpLendingV22.sol";

contract V22PrefundToken is ERC20 {
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

contract PMFIOpLendingV22PrefundRegressionTest is TestBase {
    uint256 internal constant ONE = 1e18;
    uint256 internal constant COLLATERAL_AMOUNT = 100 * ONE;
    uint256 internal constant DONATION = 7 * ONE;

    V22PrefundToken internal usdc;
    V22PrefundToken internal collateral;

    PMFIPositionFactoryV22 internal factory;
    PMFIPrimaryMarketplaceV22 internal marketplace;

    address internal borrower = makeAddr("v22PrefundBorrower");
    address internal lender = makeAddr("v22PrefundLender");
    address internal feeRecipient = makeAddr("v22PrefundFees");

    function setUp() public {
        usdc = new V22PrefundToken("USD Coin", "USDC", 6);
        collateral = new V22PrefundToken("V2.2 Prefund Collateral", "V22PF", 18);

        factory = new PMFIPositionFactoryV22(IERC20Metadata(address(usdc)), feeRecipient, address(this));

        marketplace = PMFIPrimaryMarketplaceV22(factory.marketplace());

        factory.setCollateralAllowed(address(collateral), true);

        collateral.mint(borrower, 1_000 * ONE);
        collateral.mint(address(this), 1_000 * ONE);
        usdc.mint(lender, 1_000e6);

        vm.deal(borrower, 1 ether);
    }

    function _params() internal view returns (PMFIPositionFactoryV22.CreatePositionParams memory params) {
        params = PMFIPositionFactoryV22.CreatePositionParams({
            collateral: IERC20Metadata(address(collateral)),
            collateralAmount: COLLATERAL_AMOUNT,
            targetRaiseUsdc: 100e6,
            totalRepaymentUsdc: 120e6,
            fundingDeadline: block.timestamp + 3 days,
            repaymentDeadline: block.timestamp + 33 days,
            namePrefix: "V22 PREFUND",
            symbolPrefix: "V22PF"
        });
    }

    function _create() internal returns (PMFIPositionVaultV22 vault, uint256 saleId) {
        vm.startPrank(borrower);
        collateral.approve(address(factory), COLLATERAL_AMOUNT);

        (address vaultAddress, uint256 createdSaleId) = factory.createPosition{value: factory.CREATION_FEE()}(_params());

        vm.stopPrank();

        vault = PMFIPositionVaultV22(vaultAddress);
        saleId = createdSaleId;
    }

    function _buy(uint256 saleId, uint256 amount) internal {
        (,, uint256 totalPayment) = marketplace.quoteTotalPayment(saleId, amount);

        vm.startPrank(lender);
        usdc.approve(address(marketplace), totalPayment);
        marketplace.buy(saleId, amount, totalPayment);
        vm.stopPrank();
    }

    function _firstVaultAddress() internal view returns (address predicted) {
        // Factory constructor deploys marketplace with nonce 1.
        // The first position vault is therefore created with nonce 2.
        predicted = address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", address(factory), hex"02")))));
    }

    function test_PrefundDoesNotBlockCreationOrMintExtraClaims() public {
        address predictedVault = _firstVaultAddress();

        assertTrue(collateral.transfer(predictedVault, 1));

        vm.startPrank(borrower);
        collateral.approve(address(factory), COLLATERAL_AMOUNT);

        (address vaultAddress,) = factory.createPosition{value: factory.CREATION_FEE()}(_params());

        vm.stopPrank();

        PMFIPositionVaultV22 vault = PMFIPositionVaultV22(vaultAddress);

        assertEq(vaultAddress, predictedVault);
        assertTrue(vault.initialized());
        assertEq(vault.accountedCollateral(), COLLATERAL_AMOUNT);

        // Raw balance includes the unsolicited prefund.
        assertEq(collateral.balanceOf(vaultAddress), COLLATERAL_AMOUNT + 1);

        // Economic claims remain limited to accounted collateral.
        assertEq(vault.P().totalSupply(), COLLATERAL_AMOUNT);
        assertEq(vault.N().totalSupply(), COLLATERAL_AMOUNT);

        assertEq(vault.P().balanceOf(address(marketplace)), COLLATERAL_AMOUNT);

        assertEq(vault.N().balanceOf(borrower), COLLATERAL_AMOUNT);
    }

    function test_DonationDoesNotIncreaseDefaultRecovery() public {
        (PMFIPositionVaultV22 vault, uint256 saleId) = _create();

        assertTrue(collateral.transfer(address(vault), DONATION));

        assertEq(vault.P().totalSupply(), COLLATERAL_AMOUNT);
        assertEq(vault.N().totalSupply(), COLLATERAL_AMOUNT);
        assertEq(vault.accountedCollateral(), COLLATERAL_AMOUNT);

        _buy(saleId, COLLATERAL_AMOUNT);

        assertTrue(vault.fundingClosed());

        vm.warp(vault.repaymentDeadline() + 1);
        vault.settle();

        // Settlement must ignore unsolicited collateral.
        assertEq(vault.collateralPoolAtSettle(), COLLATERAL_AMOUNT);
        assertEq(vault.usdcPoolAtSettle(), 0);

        uint256 lenderBefore = collateral.balanceOf(lender);

        vm.prank(lender);
        vault.redeemP(COLLATERAL_AMOUNT);

        assertEq(collateral.balanceOf(lender) - lenderBefore, COLLATERAL_AMOUNT);

        // Donation remains economically unassigned.
        assertEq(collateral.balanceOf(address(vault)), DONATION);
        assertEq(vault.accountedCollateral(), 0);
    }

    function test_DonationDoesNotIncreaseBorrowerRefundClaim() public {
        (PMFIPositionVaultV22 vault, uint256 saleId) = _create();

        assertTrue(collateral.transfer(address(vault), DONATION));

        _buy(saleId, 40 * ONE);

        vm.prank(borrower);
        marketplace.cancel(saleId);

        assertEq(vault.collateralRefundClaim(), 60 * ONE);
        assertEq(vault.accountedCollateral(), 40 * ONE);
        assertEq(vault.P().totalSupply(), 40 * ONE);
        assertEq(vault.N().totalSupply(), 40 * ONE);

        uint256 borrowerBefore = collateral.balanceOf(borrower);

        vm.prank(borrower);
        vault.claimCollateralRefund(borrower);

        assertEq(collateral.balanceOf(borrower) - borrowerBefore, 60 * ONE);

        assertEq(vault.collateralRefundClaim(), 0);
        assertEq(vault.accountedCollateral(), 40 * ONE);

        // 40 tokens back outstanding P plus 7 donated tokens.
        assertEq(collateral.balanceOf(address(vault)), 47 * ONE);
    }
}
