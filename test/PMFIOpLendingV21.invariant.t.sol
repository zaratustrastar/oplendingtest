// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {PMFIPositionFactoryV21, PMFIPositionVaultV21, PMFIPrimaryMarketplaceV21} from "../src/PMFIOpLendingV21.sol";

contract InvariantMockERC20 is ERC20 {
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

contract ExerciseHandler is TestBase {
    PMFIPositionVaultV21 public immutable vault;
    InvariantMockERC20 public immutable usdc;
    address public immutable borrower;

    constructor(PMFIPositionVaultV21 vault_, InvariantMockERC20 usdc_, address borrower_) {
        vault = vault_;
        usdc = usdc_;
        borrower = borrower_;
    }

    function exercise(uint256 seed) external {
        uint256 nBalance = vault.N().balanceOf(borrower);
        if (nBalance == 0) return;

        uint256 amount = bound(seed, 1, nBalance);
        if (vault.usdcOwed(amount) == 0) return;

        vm.prank(borrower);
        vault.exercise(amount);
    }
}

contract PMFIOpLendingV21InvariantTest is TestBase {
    InvariantMockERC20 internal usdc;
    InvariantMockERC20 internal collateral;
    PMFIPositionFactoryV21 internal factory;
    PMFIPrimaryMarketplaceV21 internal marketplace;
    PMFIPositionVaultV21 internal vault;
    ExerciseHandler internal handler;

    address internal borrower = makeAddr("invariantBorrower");
    address internal lender = makeAddr("invariantLender");
    address internal feeRecipient = makeAddr("invariantFeeRecipient");

    uint256 internal constant INITIAL_COLLATERAL = 1_000e18;
    uint256 internal constant TOTAL_REPAYMENT = 1_234_567_891;

    function setUp() public {
        usdc = new InvariantMockERC20("USD Coin", "USDC", 6);
        collateral = new InvariantMockERC20("Collateral", "COL", 18);
        factory = new PMFIPositionFactoryV21(IERC20Metadata(address(usdc)), feeRecipient, address(this));
        marketplace = PMFIPrimaryMarketplaceV21(factory.marketplace());
        factory.setCollateralAllowed(address(collateral), true);

        collateral.mint(borrower, INITIAL_COLLATERAL);
        usdc.mint(borrower, TOTAL_REPAYMENT);
        usdc.mint(lender, 2_000e6);
        vm.deal(borrower, 1 ether);

        PMFIPositionFactoryV21.CreatePositionParams memory params = PMFIPositionFactoryV21.CreatePositionParams({
            collateral: IERC20Metadata(address(collateral)),
            collateralAmount: INITIAL_COLLATERAL,
            targetRaiseUsdc: 1_000e6,
            totalRepaymentUsdc: TOTAL_REPAYMENT,
            fundingDeadline: block.timestamp + 3 days,
            repaymentDeadline: block.timestamp + 33 days,
            namePrefix: "PMFI COL",
            symbolPrefix: "pCOL"
        });

        vm.startPrank(borrower);
        collateral.approve(address(factory), INITIAL_COLLATERAL);
        (address vaultAddress, uint256 saleId) = factory.createPosition{value: factory.CREATION_FEE()}(params);
        usdc.approve(vaultAddress, TOTAL_REPAYMENT);
        vm.stopPrank();

        vault = PMFIPositionVaultV21(vaultAddress);

        (,, uint256 totalPayment) = marketplace.quoteTotalPayment(saleId, INITIAL_COLLATERAL);
        vm.startPrank(lender);
        usdc.approve(address(marketplace), totalPayment);
        marketplace.buy(saleId, INITIAL_COLLATERAL, totalPayment);
        vm.stopPrank();

        handler = new ExerciseHandler(vault, usdc, borrower);
        targetContract(address(handler));
    }

    function invariant_NAccountingAlwaysBalances() public view {
        assertEq(vault.pairedN() + vault.exercisedN() + vault.N().totalSupply(), vault.initialCollateralAmount());
    }

    function invariant_PSupplyMatchesNonPairedClaims() public view {
        assertEq(vault.P().totalSupply(), vault.initialCollateralAmount() - vault.pairedN());
    }

    function invariant_ValueBackingBeforeSettlement() public view {
        if (!vault.settled()) {
            assertEq(collateral.balanceOf(address(vault)) + vault.exercisedN(), vault.P().totalSupply());
            assertEq(usdc.balanceOf(address(vault)), vault.usdcPaid());
        }
    }

    function invariant_RepaymentNeverExceedsRequired() public view {
        assertLe(vault.usdcPaid(), vault.repaymentRequiredUsdc());
    }
}
