// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {PMFIPositionFactoryV21, PMFIPositionVaultV21, PMFIPrimaryMarketplaceV21} from "../src/PMFIOpLendingV21.sol";

contract AdversarialERC20 is ERC20 {
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

/// @dev Legacy-style ERC-20 that returns no value from transfer functions.
contract NoReturnCollateral {
    string public name = "No Return Collateral";
    string public symbol = "NORET";
    uint8 public immutable decimals = 18;

    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external {
        uint256 permitted = allowance[from][msg.sender];

        if (permitted != type(uint256).max) {
            allowance[from][msg.sender] = permitted - amount;
        }

        _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @dev ERC-20 that explicitly returns false from transferFrom.
contract FalseReturnCollateral is AdversarialERC20 {
    constructor() AdversarialERC20("False Return", "FALSE", 18) {}

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        return false;
    }
}

contract PausableCollateral is AdversarialERC20 {
    bool public paused;

    error TokenPaused();

    constructor() AdversarialERC20("Pausable Collateral", "PAUSE", 18) {}

    function setPaused(bool value) external {
        paused = value;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (paused && from != address(0) && to != address(0)) {
            revert TokenPaused();
        }

        super._update(from, to, amount);
    }
}

contract BlocklistUsdc is AdversarialERC20 {
    mapping(address => bool) public blocked;

    error BlockedAddress();

    constructor() AdversarialERC20("Blocklist USDC", "bUSDC", 6) {}

    function setBlocked(address account, bool value) external {
        blocked[account] = value;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if ((from != address(0) && blocked[from]) || (to != address(0) && blocked[to])) {
            revert BlockedAddress();
        }

        super._update(from, to, amount);
    }
}

contract SlashableCollateral is AdversarialERC20 {
    constructor() AdversarialERC20("Slashable Collateral", "SLASH", 18) {}

    function slash(address account, uint256 amount) external {
        _burn(account, amount);
    }
}

contract PMFIOpLendingV21AdversarialTest is TestBase {
    address internal borrower = makeAddr("adversarialBorrower");
    address internal lender = makeAddr("adversarialLender");
    address internal feeRecipient = makeAddr("adversarialFeeRecipient");

    uint256 internal constant ONE = 1e18;
    uint256 internal constant CREATION_FEE = 0.0001 ether;

    bytes4 internal constant SAFE_ERC20_FAILED_OPERATION = bytes4(keccak256("SafeERC20FailedOperation(address)"));

    function setUp() public {
        vm.deal(borrower, 10 ether);
    }

    function _deployFactory(IERC20Metadata usdc)
        internal
        returns (PMFIPositionFactoryV21 factory, PMFIPrimaryMarketplaceV21 marketplace)
    {
        factory = new PMFIPositionFactoryV21(usdc, feeRecipient, address(this));

        marketplace = PMFIPrimaryMarketplaceV21(factory.marketplace());
    }

    function _params(IERC20Metadata collateral, uint256 collateralAmount, uint256 raiseUsdc, uint256 repaymentUsdc)
        internal
        view
        returns (PMFIPositionFactoryV21.CreatePositionParams memory params)
    {
        params = PMFIPositionFactoryV21.CreatePositionParams({
            collateral: collateral,
            collateralAmount: collateralAmount,
            targetRaiseUsdc: raiseUsdc,
            totalRepaymentUsdc: repaymentUsdc,
            fundingDeadline: block.timestamp + 3 days,
            repaymentDeadline: block.timestamp + 33 days,
            namePrefix: "PMFI ADV",
            symbolPrefix: "pADV"
        });
    }

    function _createStandard(PMFIPositionFactoryV21 factory, IERC20Metadata collateral, uint256 amount)
        internal
        returns (PMFIPositionVaultV21 vault, uint256 saleId)
    {
        PMFIPositionFactoryV21.CreatePositionParams memory params = _params(collateral, amount, 100e6, 120e6);

        vm.startPrank(borrower);
        collateral.approve(address(factory), amount);

        (address vaultAddress, uint256 createdSaleId) = factory.createPosition{value: CREATION_FEE}(params);

        vm.stopPrank();

        vault = PMFIPositionVaultV21(vaultAddress);
        saleId = createdSaleId;
    }

    function _buy(PMFIPrimaryMarketplaceV21 marketplace, IERC20Metadata usdc, uint256 saleId, uint256 pAmount)
        internal
    {
        (,, uint256 totalPayment) = marketplace.quoteTotalPayment(saleId, pAmount);

        vm.startPrank(lender);
        usdc.approve(address(marketplace), totalPayment);
        marketplace.buy(saleId, pAmount, totalPayment);
        vm.stopPrank();
    }

    function test_NoReturnCollateralSupportsExactTransferLifecycle() public {
        AdversarialERC20 usdc = new AdversarialERC20("USD Coin", "USDC", 6);

        NoReturnCollateral collateral = new NoReturnCollateral();

        (PMFIPositionFactoryV21 factory, PMFIPrimaryMarketplaceV21 marketplace) =
            _deployFactory(IERC20Metadata(address(usdc)));

        factory.setCollateralAllowed(address(collateral), true);

        uint256 amount = 100 * ONE;

        collateral.mint(borrower, amount);
        usdc.mint(lender, 1_000e6);

        PMFIPositionFactoryV21.CreatePositionParams memory params =
            _params(IERC20Metadata(address(collateral)), amount, 100e6, 120e6);

        vm.startPrank(borrower);
        collateral.approve(address(factory), amount);

        (address vaultAddress, uint256 saleId) = factory.createPosition{value: CREATION_FEE}(params);

        vm.stopPrank();

        PMFIPositionVaultV21 vault = PMFIPositionVaultV21(vaultAddress);

        _buy(marketplace, IERC20Metadata(address(usdc)), saleId, 40 * ONE);

        vm.prank(borrower);
        marketplace.cancel(saleId);

        assertTrue(vault.fundingClosed());
        assertEq(collateral.balanceOf(address(vault)), 40 * ONE);
        assertEq(collateral.balanceOf(borrower), 60 * ONE);
    }

    function test_FalseReturnCollateralIsRejectedAtomically() public {
        AdversarialERC20 usdc = new AdversarialERC20("USD Coin", "USDC", 6);

        FalseReturnCollateral collateral = new FalseReturnCollateral();

        (PMFIPositionFactoryV21 factory,) = _deployFactory(IERC20Metadata(address(usdc)));

        factory.setCollateralAllowed(address(collateral), true);

        uint256 amount = 100 * ONE;

        collateral.mint(borrower, amount);

        PMFIPositionFactoryV21.CreatePositionParams memory params =
            _params(IERC20Metadata(address(collateral)), amount, 100e6, 120e6);

        vm.startPrank(borrower);
        collateral.approve(address(factory), amount);

        vm.expectRevert(abi.encodeWithSelector(SAFE_ERC20_FAILED_OPERATION, address(collateral)));
        factory.createPosition{value: CREATION_FEE}(params);

        vm.stopPrank();

        assertEq(collateral.balanceOf(borrower), amount);
        assertEq(factory.allVaultsLength(), 0);
    }

    function test_PausedCollateralMakesCancelRevertAtomically() public {
        AdversarialERC20 usdc = new AdversarialERC20("USD Coin", "USDC", 6);

        PausableCollateral collateral = new PausableCollateral();

        (PMFIPositionFactoryV21 factory, PMFIPrimaryMarketplaceV21 marketplace) =
            _deployFactory(IERC20Metadata(address(usdc)));

        factory.setCollateralAllowed(address(collateral), true);

        uint256 amount = 100 * ONE;

        collateral.mint(borrower, amount);
        usdc.mint(lender, 1_000e6);

        (PMFIPositionVaultV21 vault, uint256 saleId) =
            _createStandard(factory, IERC20Metadata(address(collateral)), amount);

        _buy(marketplace, IERC20Metadata(address(usdc)), saleId, 40 * ONE);

        collateral.setPaused(true);

        vm.expectRevert(PausableCollateral.TokenPaused.selector);
        vm.prank(borrower);
        marketplace.cancel(saleId);

        assertFalse(vault.fundingClosed());
        assertEq(collateral.balanceOf(address(vault)), amount);
        assertEq(vault.P().balanceOf(address(marketplace)), 60 * ONE);

        collateral.setPaused(false);

        vm.prank(borrower);
        marketplace.cancel(saleId);

        assertTrue(vault.fundingClosed());
        assertEq(collateral.balanceOf(address(vault)), 40 * ONE);
        assertEq(collateral.balanceOf(borrower), 60 * ONE);
    }

    function test_BlocklistedBorrowerMakesBuyRevertAtomically() public {
        BlocklistUsdc usdc = new BlocklistUsdc();

        AdversarialERC20 collateral = new AdversarialERC20("Collateral", "COL", 18);

        (PMFIPositionFactoryV21 factory, PMFIPrimaryMarketplaceV21 marketplace) =
            _deployFactory(IERC20Metadata(address(usdc)));

        factory.setCollateralAllowed(address(collateral), true);

        uint256 amount = 100 * ONE;

        collateral.mint(borrower, amount);
        usdc.mint(lender, 1_000e6);

        (PMFIPositionVaultV21 vault, uint256 saleId) =
            _createStandard(factory, IERC20Metadata(address(collateral)), amount);

        (,, uint256 totalPayment) = marketplace.quoteTotalPayment(saleId, amount);

        vm.prank(lender);
        usdc.approve(address(marketplace), totalPayment);

        usdc.setBlocked(borrower, true);

        vm.expectRevert(BlocklistUsdc.BlockedAddress.selector);
        vm.prank(lender);
        marketplace.buy(saleId, amount, totalPayment);

        assertEq(usdc.balanceOf(lender), 1_000e6);
        assertEq(usdc.balanceOf(address(marketplace)), 0);
        assertEq(usdc.balanceOf(borrower), 0);
        assertEq(marketplace.accruedProtocolFees(), 0);
        assertEq(vault.P().balanceOf(address(marketplace)), amount);
        assertFalse(vault.fundingClosed());

        usdc.setBlocked(borrower, false);

        vm.prank(lender);
        marketplace.buy(saleId, amount, totalPayment);

        assertTrue(vault.fundingClosed());
        assertEq(usdc.balanceOf(borrower), 100e6);
        assertEq(marketplace.accruedProtocolFees(), 100_000);
    }

    function test_NegativeRebaseCanReducePHolderRecovery() public {
        AdversarialERC20 usdc = new AdversarialERC20("USD Coin", "USDC", 6);

        SlashableCollateral collateral = new SlashableCollateral();

        (PMFIPositionFactoryV21 factory, PMFIPrimaryMarketplaceV21 marketplace) =
            _deployFactory(IERC20Metadata(address(usdc)));

        factory.setCollateralAllowed(address(collateral), true);

        uint256 amount = 100 * ONE;

        collateral.mint(borrower, amount);
        usdc.mint(lender, 1_000e6);

        (PMFIPositionVaultV21 vault, uint256 saleId) =
            _createStandard(factory, IERC20Metadata(address(collateral)), amount);

        _buy(marketplace, IERC20Metadata(address(usdc)), saleId, amount);

        collateral.slash(address(vault), 10 * ONE);

        vm.warp(vault.repaymentDeadline() + 1);

        vm.prank(lender);
        vault.settleAndRedeemP(amount);

        assertEq(collateral.balanceOf(lender), 90 * ONE);
        assertEq(collateral.balanceOf(address(vault)), 0);
        assertEq(vault.P().totalSupply(), 0);
    }
}
