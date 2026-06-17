// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestBase} from "./TestBase.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {PMFIPositionFactoryV22} from "../src/PMFIOpLendingV22.sol";

contract V22StrictAllowlistToken is ERC20 {
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

contract PMFIOpLendingV22StrictAllowlistRegressionTest is TestBase {
    uint256 internal constant ONE = 1e18;
    uint256 internal constant COLLATERAL_AMOUNT = 100 * ONE;

    V22StrictAllowlistToken internal usdc;
    V22StrictAllowlistToken internal collateralA;
    V22StrictAllowlistToken internal collateralB;

    PMFIPositionFactoryV22 internal factory;

    address internal borrower = makeAddr("v22AllowlistBorrower");

    address internal secondBorrower = makeAddr("v22AllowlistSecondBorrower");

    address internal safeOwner = makeAddr("v22AllowlistSafe");

    address internal feeRecipient = makeAddr("v22AllowlistFees");

    function setUp() public {
        usdc = new V22StrictAllowlistToken("USD Coin", "USDC", 6);

        collateralA = new V22StrictAllowlistToken("V2.2 Collateral A", "V22A", 18);

        collateralB = new V22StrictAllowlistToken("V2.2 Collateral B", "V22B", 18);

        factory = new PMFIPositionFactoryV22(IERC20Metadata(address(usdc)), feeRecipient, address(this));

        collateralA.mint(borrower, 1_000 * ONE);

        collateralA.mint(secondBorrower, 1_000 * ONE);

        collateralB.mint(borrower, 1_000 * ONE);

        collateralB.mint(secondBorrower, 1_000 * ONE);

        vm.deal(borrower, 10 ether);
        vm.deal(secondBorrower, 10 ether);
    }

    function _params(V22StrictAllowlistToken collateralToken)
        internal
        view
        returns (PMFIPositionFactoryV22.CreatePositionParams memory params)
    {
        params = PMFIPositionFactoryV22.CreatePositionParams({
            collateral: IERC20Metadata(address(collateralToken)),
            collateralAmount: COLLATERAL_AMOUNT,
            targetRaiseUsdc: 100e6,
            totalRepaymentUsdc: 120e6,
            fundingDeadline: block.timestamp + 3 days,
            repaymentDeadline: block.timestamp + 33 days,
            namePrefix: "V22 STRICT",
            symbolPrefix: "V22S"
        });
    }

    function _create(address creator, V22StrictAllowlistToken collateralToken)
        internal
        returns (address vault, uint256 saleId)
    {
        vm.startPrank(creator);

        collateralToken.approve(address(factory), COLLATERAL_AMOUNT);

        (vault, saleId) = factory.createPosition{value: factory.CREATION_FEE()}(_params(collateralToken));

        vm.stopPrank();
    }

    function test_PermissionlessCollateralEntryPointIsRemoved() public {
        (bool success,) = address(factory).call(abi.encodeWithSignature("setPermissionlessCollateral(bool)", true));

        assertFalse(success);
    }

    function test_UnallowlistedCollateralCannotBeEnabledByOwner() public {
        (bool bypassCallSucceeded,) =
            address(factory).call(abi.encodeWithSignature("setPermissionlessCollateral(bool)", true));

        vm.startPrank(borrower);

        collateralA.approve(address(factory), COLLATERAL_AMOUNT);

        uint256 creationFee = factory.CREATION_FEE();

        PMFIPositionFactoryV22.CreatePositionParams memory params = _params(collateralA);

        vm.expectRevert(PMFIPositionFactoryV22.CollateralNotAllowed.selector);

        factory.createPosition{value: creationFee}(params);

        vm.stopPrank();

        // After the production fix the obsolete setter must not exist.
        assertFalse(bypassCallSucceeded);
    }

    function test_ExplicitlyAllowlistedCollateralCanCreatePosition() public {
        factory.setCollateralAllowed(address(collateralA), true);

        (address vault,) = _create(borrower, collateralA);

        assertTrue(factory.isVault(vault));

        assertEq(factory.creatorOf(vault), borrower);
    }

    function test_DelistingBlocksNewPositionsButPreservesExistingVault() public {
        factory.setCollateralAllowed(address(collateralA), true);

        (address existingVault,) = _create(borrower, collateralA);

        factory.setCollateralAllowed(address(collateralA), false);

        vm.startPrank(secondBorrower);

        collateralA.approve(address(factory), COLLATERAL_AMOUNT);

        uint256 creationFee = factory.CREATION_FEE();

        PMFIPositionFactoryV22.CreatePositionParams memory params = _params(collateralA);

        vm.expectRevert(PMFIPositionFactoryV22.CollateralNotAllowed.selector);

        factory.createPosition{value: creationFee}(params);

        vm.stopPrank();

        assertTrue(factory.isVault(existingVault));

        assertEq(factory.creatorOf(existingVault), borrower);
    }

    function test_TwoStepOwnerControlsCollateralAllowlist() public {
        assertEq(factory.owner(), address(this));

        factory.transferOwnership(safeOwner);

        assertEq(factory.owner(), address(this));

        assertEq(factory.pendingOwner(), safeOwner);

        vm.prank(safeOwner);
        factory.acceptOwnership();

        assertEq(factory.owner(), safeOwner);

        assertEq(factory.pendingOwner(), address(0));

        (bool oldOwnerSucceeded,) = address(factory)
            .call(abi.encodeWithSignature("setCollateralAllowed(address,bool)", address(collateralB), true));

        assertFalse(oldOwnerSucceeded);

        assertFalse(factory.collateralAllowed(address(collateralB)));

        vm.prank(safeOwner);

        factory.setCollateralAllowed(address(collateralB), true);

        assertTrue(factory.collateralAllowed(address(collateralB)));
    }
}
