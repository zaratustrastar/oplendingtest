// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {PMFIPositionFactoryV22, PMFIPositionVaultV22, PMFIPrimaryMarketplaceV22} from "../src/PMFIOpLendingV22.sol";

contract V22FullRepaymentToken is ERC20 {
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

contract V22FullRepaymentBlockingCollateral is V22FullRepaymentToken {
    address public blockedSender;
    bool public blocked;

    error OutboundBlocked();

    constructor() V22FullRepaymentToken("V2.2 Full Repayment Collateral", "V22FRC", 18) {}

    function configure(address sender, bool value) external {
        blockedSender = sender;
        blocked = value;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (blocked && from == blockedSender && from != address(0) && to != address(0)) {
            revert OutboundBlocked();
        }

        super._update(from, to, value);
    }
}

contract PMFIOpLendingV22FullRepaymentRegressionTest is TestBase {
    uint256 internal constant ONE = 1e18;
    uint256 internal constant COLLATERAL_AMOUNT = 100 * ONE;

    V22FullRepaymentToken internal usdc;
    V22FullRepaymentBlockingCollateral internal collateral;

    PMFIPositionFactoryV22 internal factory;
    PMFIPrimaryMarketplaceV22 internal marketplace;

    address internal borrower = makeAddr("v22FullRepaymentBorrower");
    address internal lender = makeAddr("v22FullRepaymentLender");
    address internal other = makeAddr("v22FullRepaymentOther");
    address internal feeRecipient = makeAddr("v22FullRepaymentFees");

    function setUp() public {
        usdc = new V22FullRepaymentToken("USD Coin", "USDC", 6);
        collateral = new V22FullRepaymentBlockingCollateral();

        factory = new PMFIPositionFactoryV22(IERC20Metadata(address(usdc)), feeRecipient, address(this));

        marketplace = PMFIPrimaryMarketplaceV22(factory.marketplace());

        factory.setCollateralAllowed(address(collateral), true);

        collateral.mint(borrower, 1_000 * ONE);
        usdc.mint(borrower, 1_000e6);
        usdc.mint(lender, 1_000e6);
        usdc.mint(other, 1_000e6);

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
            namePrefix: "V22 FULL REPAYMENT",
            symbolPrefix: "V22FR"
        });

        vm.startPrank(borrower);
        collateral.approve(address(factory), COLLATERAL_AMOUNT);

        (address vaultAddress, uint256 createdSaleId) = factory.createPosition{value: factory.CREATION_FEE()}(params);

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

    function _callRepayInFull(PMFIPositionVaultV22 vault, address caller) internal returns (bool success) {
        vm.prank(caller);

        (success,) = address(vault).call(abi.encodeWithSignature("repayInFull()"));
    }

    function test_NRemainsNonTransferableAfterFundingCloses() public {
        (PMFIPositionVaultV22 vault, uint256 saleId) = _create();

        _buy(saleId, COLLATERAL_AMOUNT);

        assertTrue(vault.fundingClosed());
        assertEq(vault.N().balanceOf(borrower), COLLATERAL_AMOUNT);

        address nToken = address(vault.N());

        vm.prank(borrower);

        (bool transferred,) = nToken.call(abi.encodeWithSignature("transfer(address,uint256)", lender, ONE));

        assertFalse(transferred);
        assertEq(vault.N().balanceOf(borrower), COLLATERAL_AMOUNT);
        assertEq(vault.N().balanceOf(lender), 0);
    }

    function test_PartialExerciseEntryPointIsDisabled() public {
        (PMFIPositionVaultV22 vault, uint256 saleId) = _create();

        _buy(saleId, COLLATERAL_AMOUNT);

        uint256 borrowerUsdcBefore = usdc.balanceOf(borrower);
        uint256 borrowerCollateralBefore = collateral.balanceOf(borrower);

        vm.startPrank(borrower);
        usdc.approve(address(vault), 60e6);

        (bool exercised,) = address(vault).call(abi.encodeWithSignature("exercise(uint256)", 50 * ONE));

        vm.stopPrank();

        assertFalse(exercised);
        assertEq(usdc.balanceOf(borrower), borrowerUsdcBefore);
        assertEq(collateral.balanceOf(borrower), borrowerCollateralBefore);
        assertEq(vault.N().totalSupply(), COLLATERAL_AMOUNT);
        assertEq(vault.accountedCollateral(), COLLATERAL_AMOUNT);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    function test_FullRepaymentUsesExactFundedObligation() public {
        (PMFIPositionVaultV22 vault, uint256 saleId) = _create();

        _buy(saleId, 40 * ONE);

        vm.prank(borrower);
        marketplace.cancel(saleId);

        uint256 required = vault.repaymentRequiredUsdc();

        // 40% of the position was funded:
        // 40% of 120 USDC total repayment = 48 USDC.
        assertEq(required, 48e6);
        assertEq(vault.P().totalSupply(), 40 * ONE);
        assertEq(vault.N().totalSupply(), 40 * ONE);
        assertEq(vault.accountedCollateral(), 40 * ONE);
        assertEq(vault.collateralRefundClaim(), 60 * ONE);

        uint256 borrowerUsdcBefore = usdc.balanceOf(borrower);
        uint256 borrowerCollateralBefore = collateral.balanceOf(borrower);

        vm.prank(borrower);
        usdc.approve(address(vault), required);

        bool repaid = _callRepayInFull(vault, borrower);

        assertTrue(repaid);

        assertEq(borrowerUsdcBefore - usdc.balanceOf(borrower), required);
        assertEq(usdc.balanceOf(address(vault)), required);
        assertEq(vault.usdcPaid(), required);
        assertEq(vault.repaymentRemainingUsdc(), 0);

        assertEq(collateral.balanceOf(borrower) - borrowerCollateralBefore, 40 * ONE);

        assertEq(vault.N().totalSupply(), 0);
        assertEq(vault.P().totalSupply(), 40 * ONE);
        assertEq(vault.accountedCollateral(), 0);

        // The separate unsold-collateral refund remains intact.
        assertEq(vault.collateralRefundClaim(), 60 * ONE);
        assertEq(collateral.balanceOf(address(vault)), 60 * ONE);
    }

    function test_OnlyBorrowerCanRepayInFull() public {
        (PMFIPositionVaultV22 vault, uint256 saleId) = _create();

        _buy(saleId, COLLATERAL_AMOUNT);

        uint256 required = vault.repaymentRequiredUsdc();

        vm.prank(lender);
        usdc.approve(address(vault), required);

        uint256 lenderUsdcBefore = usdc.balanceOf(lender);

        bool repaid = _callRepayInFull(vault, lender);

        assertFalse(repaid);
        assertEq(usdc.balanceOf(lender), lenderUsdcBefore);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(vault.N().totalSupply(), COLLATERAL_AMOUNT);
        assertEq(vault.accountedCollateral(), COLLATERAL_AMOUNT);
    }

    function test_InsufficientApprovalCannotPartiallyRepay() public {
        (PMFIPositionVaultV22 vault, uint256 saleId) = _create();

        _buy(saleId, COLLATERAL_AMOUNT);

        uint256 required = vault.repaymentRequiredUsdc();

        vm.prank(borrower);
        usdc.approve(address(vault), required - 1);

        uint256 borrowerUsdcBefore = usdc.balanceOf(borrower);
        uint256 borrowerCollateralBefore = collateral.balanceOf(borrower);

        bool repaid = _callRepayInFull(vault, borrower);

        assertFalse(repaid);
        assertEq(usdc.balanceOf(borrower), borrowerUsdcBefore);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(collateral.balanceOf(borrower), borrowerCollateralBefore);
        assertEq(vault.N().totalSupply(), COLLATERAL_AMOUNT);
        assertEq(vault.accountedCollateral(), COLLATERAL_AMOUNT);
    }

    function test_FailedCollateralReturnRevertsRepaymentAtomically() public {
        (PMFIPositionVaultV22 vault, uint256 saleId) = _create();

        _buy(saleId, COLLATERAL_AMOUNT);

        uint256 required = vault.repaymentRequiredUsdc();

        collateral.configure(address(vault), true);

        vm.prank(borrower);
        usdc.approve(address(vault), required);

        uint256 borrowerUsdcBefore = usdc.balanceOf(borrower);
        uint256 vaultUsdcBefore = usdc.balanceOf(address(vault));
        uint256 borrowerCollateralBefore = collateral.balanceOf(borrower);
        uint256 vaultCollateralBefore = collateral.balanceOf(address(vault));

        bool repaid = _callRepayInFull(vault, borrower);

        assertFalse(repaid);
        assertEq(usdc.balanceOf(borrower), borrowerUsdcBefore);
        assertEq(usdc.balanceOf(address(vault)), vaultUsdcBefore);
        assertEq(collateral.balanceOf(borrower), borrowerCollateralBefore);
        assertEq(collateral.balanceOf(address(vault)), vaultCollateralBefore);
        assertEq(vault.usdcPaid(), 0);
        assertEq(vault.N().totalSupply(), COLLATERAL_AMOUNT);
        assertEq(vault.accountedCollateral(), COLLATERAL_AMOUNT);
    }

    function test_FullRepaymentRejectedAfterDeadline() public {
        (PMFIPositionVaultV22 vault, uint256 saleId) = _create();

        _buy(saleId, COLLATERAL_AMOUNT);

        uint256 required = vault.repaymentRequiredUsdc();

        vm.prank(borrower);
        usdc.approve(address(vault), required);

        vm.warp(vault.repaymentDeadline() + 1);

        bool repaid = _callRepayInFull(vault, borrower);

        assertFalse(repaid);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(vault.usdcPaid(), 0);
        assertEq(vault.N().totalSupply(), COLLATERAL_AMOUNT);
        assertEq(vault.accountedCollateral(), COLLATERAL_AMOUNT);
    }
}
